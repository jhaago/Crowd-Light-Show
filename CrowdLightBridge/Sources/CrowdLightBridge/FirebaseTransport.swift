import Foundation

final class FirebaseTransport {
    private let session: URLSession
    private(set) var serverOffsetMs: Double = 0
    var authToken: String = ""

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

    func testConnection(databaseURL: String, room: String, completion: @escaping (Result<Double, Error>) -> Void) {
        let base = normalizedDatabaseURL(databaseURL)
        guard !base.isEmpty else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        fetchServerOffset(databaseURL: base) { [weak self] _ in
            guard let self else { return }
            let statusURL = "\(base)/crowdlight/\(self.pathComponent(room))/bridgeStatus.json"
            let payload: [String: Any] = [
                "online": true,
                "source": "CrowdLight Bridge",
                "version": "0.1.0",
                "lastSeen": self.estimatedServerNowMs()
            ]

            self.putJSON(urlString: statusURL, json: payload) { result in
                switch result {
                case .success:
                    completion(.success(self.serverOffsetMs))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func fetchServerOffset(databaseURL: String, completion: @escaping (Result<Double, Error>) -> Void) {
        let base = normalizedDatabaseURL(databaseURL)
        guard let url = makeURL("\(base)/.info/serverTimeOffset.json") else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session.dataTask(with: request) { [weak self] data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion(.failure(BridgeNetworkError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)))
                return
            }
            let offset: Double
            if let data,
               let number = try? JSONSerialization.jsonObject(with: data) as? NSNumber {
                offset = number.doubleValue
            } else {
                offset = 0
            }
            self?.serverOffsetMs = offset
            completion(.success(offset))
        }.resume()
    }

    func sendCommand(databaseURL: String, room: String, command: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let base = normalizedDatabaseURL(databaseURL)
        guard !base.isEmpty else {
            completion(.failure(BridgeNetworkError.invalidDatabaseURL))
            return
        }
        let url = "\(base)/crowdlight/\(pathComponent(room))/command.json?print=silent"
        putJSON(urlString: url, json: command, completion: completion)
    }

    private func putJSON(urlString: String, json: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
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
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    completion(.failure(BridgeNetworkError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)))
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
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        return raw.uppercased()
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }
}

enum BridgeNetworkError: LocalizedError {
    case invalidDatabaseURL
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidDatabaseURL:
            return "The Firebase database URL is invalid."
        case .httpStatus(let code):
            if code == 401 || code == 403 {
                return "Firebase rejected the request (HTTP \(code)). Check database rules/authentication."
            }
            return "Firebase returned HTTP \(code)."
        }
    }
}
