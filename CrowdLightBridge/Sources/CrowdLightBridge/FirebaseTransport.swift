import Foundation

final class FirebaseTransport {
    private let session: URLSession
    private let stateLock = NSLock()
    private var _serverOffsetMs: Double = 0
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
        Date().timeIntervalSince1970 * 1000 + serverOffsetMs
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
                    "version": "0.4.0",
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

            session.dataTask(with: request) { [weak self] data, response, error in
                let localEnd = Date().timeIntervalSince1970 * 1000

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
                    let offset = number.doubleValue - localMidpoint
                    self?.setServerOffset(offset)
                    completion(.success(offset))
                } catch {
                    completion(.failure(BridgeNetworkError.invalidClockResponse))
                }
            }.resume()
        } catch {
            completion(.failure(error))
        }
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

    private func setServerOffset(_ value: Double) {
        stateLock.lock()
        _serverOffsetMs = value
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

enum BridgeNetworkError: LocalizedError {
    case invalidDatabaseURL
    case httpStatus(Int)
    case invalidClockResponse
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

        case .clockSampleTooSlow(let milliseconds):
            return String(
                format: "Firebase clock sample was too slow (%.0f ms round trip).",
                milliseconds
            )
        }
    }
}
