import Foundation

final class FirebaseTransport {
    static let controlLeaseDurationMs: Double = 12_000
    static let controlLeaseGraceMs: Double = 500

    private let session: URLSession
    private let stateLock = NSLock()
    private var _serverOffsetMs: Double = 0
    private var _serverAnchorValueMs: Double = 0
    private var _serverAnchorUptime: TimeInterval = 0
    private var _serverClockSampleUptime: TimeInterval = 0
    private var _serverClockReady = false
    private let commandLock = NSLock()
    private var latestCommands: [String: (revision: UInt64, command: [String: Any])] = [:]
    var authToken: String = ""

    var serverOffsetMs: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _serverOffsetMs
    }

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config)
    }

    func normalizedDatabaseURL(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    func estimatedServerNowMs() -> Double {
        stateLock.lock()
        let ready = _serverClockReady
        let anchorValue = _serverAnchorValueMs
        let anchorUptime = _serverAnchorUptime
        let offset = _serverOffsetMs
        stateLock.unlock()

        if ready {
            let elapsed =
                (ProcessInfo.processInfo.systemUptime - anchorUptime) * 1000
            return anchorValue + elapsed
        }

        return Date().timeIntervalSince1970 * 1000 + offset
    }

    func serverClockAgeMs() -> Double {
        stateLock.lock()
        let ready = _serverClockReady
        let sampleUptime = _serverClockSampleUptime
        stateLock.unlock()

        guard ready else { return .infinity }
        return max(
            0,
            (ProcessInfo.processInfo.systemUptime - sampleUptime) * 1000
        )
    }

    func hasFreshServerClock(maxAgeMs: Double = 120_000) -> Bool {
        serverClockAgeMs() <= maxAgeMs
    }

    func testConnection(
        databaseURL: String,
        room: String,
        completion: @escaping (Result<Double, Error>) -> Void
    ) {
        let base = normalizedDatabaseURL(databaseURL)
        guard !base.isEmpty else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        // The Realtime Database REST API does not expose .info/serverTimeOffset.
        // Measure a real Firebase server timestamp instead, then verify that the
        // Bridge can also write its normal status path.
        fetchServerOffset(databaseURL: base, room: room) { [weak self] clockResult in
            guard let self else { return }

            switch clockResult {
            case .failure(let error):
                completion(.failure(error))

            case .success(let offset):
                let statusURL = "\(base)/crowdlight/\(self.pathComponent(room))/bridgeStatus.json"
                let payload: [String: Any] = [
                    "online": true,
                    "source": "CrowdLight Bridge",
                    "version": "0.5.0",
                    "lastSeen": self.estimatedServerNowMs()
                ]

                self.putJSON(urlString: statusURL, json: payload) { result in
                    switch result {
                    case .success:
                        completion(.success(offset))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func fetchServerOffset(
        databaseURL: String,
        room: String,
        completion: @escaping (Result<Double, Error>) -> Void
    ) {
        let base = normalizedDatabaseURL(databaseURL)
        let probeURL = "\(base)/crowdlight/\(pathComponent(room))/bridgeClockProbe.json"

        guard let url = makeURL(probeURL) else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        do {
            let body = try JSONSerialization.data(
                withJSONObject: [".sv": "timestamp"],
                options: []
            )
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = body
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let localStart = Date().timeIntervalSince1970 * 1000
            let uptimeStart = ProcessInfo.processInfo.systemUptime

            session.dataTask(with: request) { [weak self] data, response, error in
                let localEnd = Date().timeIntervalSince1970 * 1000
                let uptimeEnd = ProcessInfo.processInfo.systemUptime

                if let error {
                    completion(.failure(error))
                    return
                }

                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    completion(
                        .failure(
                            BridgeNetworkError.httpStatus(
                                (response as? HTTPURLResponse)?.statusCode ?? -1
                            )
                        )
                    )
                    return
                }

                guard let data else {
                    completion(.failure(BridgeNetworkError.invalidClockResponse))
                    return
                }

                do {
                    let object = try JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    )
                    guard let number = object as? NSNumber else {
                        completion(.failure(BridgeNetworkError.invalidClockResponse))
                        return
                    }

                    let roundTripMs = localEnd - localStart
                    guard roundTripMs >= 0, roundTripMs <= 2_000 else {
                        completion(.failure(BridgeNetworkError.clockSampleTooSlow(roundTripMs)))
                        return
                    }

                    // Estimate server time at the midpoint of the request.
                    let localMidpoint = (localStart + localEnd) / 2
                    let uptimeMidpoint = (uptimeStart + uptimeEnd) / 2
                    let serverAtMidpoint = number.doubleValue
                    let offset = serverAtMidpoint - localMidpoint
                    self?.setServerClock(
                        offset: offset,
                        serverAtMidpoint: serverAtMidpoint,
                        uptimeMidpoint: uptimeMidpoint,
                        sampleUptime: uptimeEnd
                    )
                    completion(.success(offset))
                } catch {
                    completion(.failure(BridgeNetworkError.invalidClockResponse))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    static func canAcquireLease(
        currentControllerID: String?,
        currentLeaseID: String?,
        currentLeaseUntil: Double?,
        requestControllerID: String,
        requestLeaseID: String,
        now: Double,
        force: Bool
    ) -> Bool {
        if force { return true }

        let active = (currentLeaseUntil ?? 0) > now - controlLeaseGraceMs
        if !active { return true }

        return currentControllerID == requestControllerID &&
            currentLeaseID == requestLeaseID
    }

    func acquireRoomLease(
        databaseURL: String,
        room: String,
        controllerID: String,
        leaseID: String,
        force: Bool,
        completion: @escaping (Result<BridgeLeaseResult, Error>) -> Void
    ) {
        let base = normalizedDatabaseURL(databaseURL)
        guard !base.isEmpty else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        acquireRoomLeaseAttempt(
            databaseURL: base,
            room: room,
            controllerID: controllerID,
            leaseID: leaseID,
            force: force,
            attempt: 0,
            completion: completion
        )
    }

    private func acquireRoomLeaseAttempt(
        databaseURL: String,
        room: String,
        controllerID: String,
        leaseID: String,
        force: Bool,
        attempt: Int,
        completion: @escaping (Result<BridgeLeaseResult, Error>) -> Void
    ) {
        let roomPath = pathComponent(room)
        let urlString = "\(databaseURL)/crowdlight/\(roomPath)/controlLease.json"
        guard let url = makeURL(urlString) else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("true", forHTTPHeaderField: "X-Firebase-ETag")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                completion(.failure(error))
                return
            }

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode)
            else {
                completion(
                    .failure(
                        BridgeNetworkError.httpStatus(
                            (response as? HTTPURLResponse)?.statusCode ?? -1
                        )
                    )
                )
                return
            }

            let etag = http.value(forHTTPHeaderField: "ETag") ?? "null_etag"
            var current: [String: Any] = [:]
            if let data, !data.isEmpty {
                do {
                    let object = try JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    )
                    if let dict = object as? [String: Any] {
                        current = dict
                    }
                } catch {
                    completion(.failure(BridgeNetworkError.invalidLeaseResponse))
                    return
                }
            }

            let currentController = current["controllerId"] as? String
            let currentLeaseID = current["leaseId"] as? String
            let currentUntil = (current["leaseUntil"] as? NSNumber)?.doubleValue
            let now = self.estimatedServerNowMs()

            let mayAcquire = Self.canAcquireLease(
                currentControllerID: currentController,
                currentLeaseID: currentLeaseID,
                currentLeaseUntil: currentUntil,
                requestControllerID: controllerID,
                requestLeaseID: leaseID,
                now: now,
                force: force
            )

            guard mayAcquire else {
                completion(
                    .success(
                        .held(
                            ownerType: current["ownerType"] as? String ?? "controller",
                            controllerID: currentController ?? "unknown",
                            leaseUntil: currentUntil ?? 0
                        )
                    )
                )
                return
            }

            let sameLease = currentController == controllerID &&
                currentLeaseID == leaseID &&
                (currentUntil ?? 0) > now - Self.controlLeaseGraceMs

            let payload: [String: Any] = [
                "protocolVersion": 1,
                "controllerId": controllerID,
                "leaseId": leaseID,
                "ownerType": "bridge",
                "acquiredAt": sameLease
                    ? ((current["acquiredAt"] as? NSNumber)?.doubleValue ?? now)
                    : now,
                "leaseUntil": now + Self.controlLeaseDurationMs
            ]

            do {
                let body = try JSONSerialization.data(
                    withJSONObject: payload,
                    options: []
                )
                var put = URLRequest(url: url)
                put.httpMethod = "PUT"
                put.httpBody = body
                put.setValue("application/json", forHTTPHeaderField: "Content-Type")
                put.setValue(etag, forHTTPHeaderField: "if-match")

                self.session.dataTask(with: put) { _, putResponse, putError in
                    if let putError {
                        completion(.failure(putError))
                        return
                    }

                    let status = (putResponse as? HTTPURLResponse)?.statusCode ?? -1
                    if status == 412, attempt < 3 {
                        self.acquireRoomLeaseAttempt(
                            databaseURL: databaseURL,
                            room: room,
                            controllerID: controllerID,
                            leaseID: leaseID,
                            force: force,
                            attempt: attempt + 1,
                            completion: completion
                        )
                        return
                    }

                    guard (200..<300).contains(status) else {
                        completion(.failure(BridgeNetworkError.httpStatus(status)))
                        return
                    }

                    completion(
                        .success(
                            .acquired(
                                leaseUntil: now + Self.controlLeaseDurationMs
                            )
                        )
                    )
                }.resume()
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func sendCommand(
        databaseURL: String,
        room: String,
        command: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let base = normalizedDatabaseURL(databaseURL)
        guard !base.isEmpty else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        let roomPath = pathComponent(room)
        let key = base + "|" + roomPath
        let revision = commandRevision(command)

        if revision > 0 {
            commandLock.lock()
            if latestCommands[key]?.revision ?? 0 <= revision {
                latestCommands[key] = (revision, command)
            }
            commandLock.unlock()
        }

        let url = "\(base)/crowdlight/\(roomPath)/command.json?print=silent"
        putJSON(urlString: url, json: command) { [weak self] result in
            completion(result)

            // A REST task can finish after a newer command task. If that
            // happens, immediately write the newest revision again so Firebase
            // cannot remain stuck on the stale command.
            if case .success = result, revision > 0 {
                self?.repairIfSuperseded(
                    key: key,
                    appliedRevision: revision,
                    urlString: url
                )
            }
        }
    }

    private func commandRevision(_ command: [String: Any]) -> UInt64 {
        if let number = command["revision"] as? NSNumber {
            return number.uint64Value
        }
        if let value = command["revision"] as? UInt64 {
            return value
        }
        if let value = command["revision"] as? Int, value >= 0 {
            return UInt64(value)
        }
        return 0
    }

    private func repairIfSuperseded(
        key: String,
        appliedRevision: UInt64,
        urlString: String
    ) {
        commandLock.lock()
        let newest = latestCommands[key]
        commandLock.unlock()

        guard let newest, newest.revision > appliedRevision else { return }

        putJSON(urlString: urlString, json: newest.command) { [weak self] result in
            guard case .success = result else { return }
            // Another cue may have become newest while this repair was in
            // flight, so check once more using the revision just applied.
            self?.repairIfSuperseded(
                key: key,
                appliedRevision: newest.revision,
                urlString: urlString
            )
        }
    }

    private func setServerClock(
        offset: Double,
        serverAtMidpoint: Double,
        uptimeMidpoint: TimeInterval,
        sampleUptime: TimeInterval
    ) {
        stateLock.lock()
        _serverOffsetMs = offset
        _serverAnchorValueMs = serverAtMidpoint
        _serverAnchorUptime = uptimeMidpoint
        _serverClockSampleUptime = sampleUptime
        _serverClockReady = true
        stateLock.unlock()
    }

    private func putJSON(
        urlString: String,
        json: [String: Any],
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let url = makeURL(urlString) else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            session.dataTask(with: request) { _, response, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode)
                else {
                    completion(
                        .failure(
                            BridgeNetworkError.httpStatus(
                                (response as? HTTPURLResponse)?.statusCode ?? -1
                            )
                        )
                    )
                    return
                }
                completion(.success(()))
            }.resume()
        } catch {
            completion(.failure(error))
        }
    }

    private func makeURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else { return nil }
        if !authToken.isEmpty {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "auth", value: authToken))
            components.queryItems = items
        }
        return components.url
    }

    private func pathComponent(_ raw: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
        )
        let cleaned = raw.uppercased()
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
        return cleaned.isEmpty ? "MAIN" : String(cleaned.prefix(24))
    }
}

enum BridgeLeaseResult: Equatable {
    case acquired(leaseUntil: Double)
    case held(ownerType: String, controllerID: String, leaseUntil: Double)
}

enum BridgeNetworkError: LocalizedError {
    case invalidDatabaseURL
    case httpStatus(Int)
    case invalidClockResponse
    case invalidLeaseResponse
    case clockSampleTooSlow(Double)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL:
            return "The Firebase database URL is invalid."

        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Firebase rejected the request (HTTP \(code)). Check database rules/authentication."
            }
            return "Firebase returned HTTP \(code)."

        case .invalidClockResponse:
            return "Firebase did not return a valid server timestamp."

        case .invalidLeaseResponse:
            return "Firebase returned an invalid CrowdLight controller lease."

        case .clockSampleTooSlow(let milliseconds):
            return String(
                format: "Firebase clock sample was too slow (%.0f ms round trip).",
                milliseconds
            )
        }
    }
}
