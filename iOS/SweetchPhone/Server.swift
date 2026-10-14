import Foundation

/// sweetch on the Mac, reached over Tailscale: see DictationServer.swift there.
struct Server {
    var address: String
    var token: String

    static let addressKey = "serverAddress"
    static let tokenKey = "serverToken"
    static let defaultAddress = "http://100.85.3.88:8180"

    static var current: Server {
        let defaults = UserDefaults.standard
        return Server(address: defaults.string(forKey: addressKey) ?? defaultAddress,
                      token: defaults.string(forKey: tokenKey) ?? "")
    }

    func ping() async -> Bool {
        guard let url = URL(string: address + "/ping") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Hands over what's on screen; the Mac reads it while the user speaks. Returns the id the
    /// recording goes with.
    func context(screenshot: Data?, fieldBefore: String?) async throws -> String {
        var body: [String: Any] = [:]
        if let screenshot { body["screenshot"] = screenshot.base64EncodedString() }
        if let fieldBefore { body["field_before"] = fieldBefore }
        let reply = try await send("/context", body: try JSONSerialization.data(withJSONObject: body), timeout: 10)
        guard let id = reply["id"] as? String else { throw Failure("the Mac gave no id") }
        return id
    }

    /// What the Mac heard in `recording`.
    func hear(_ recording: Data, contextID: String?, apple: String?) async throws -> String {
        var query = URLComponents()
        query.queryItems = [contextID.map { URLQueryItem(name: "id", value: $0) },
                            apple.map { URLQueryItem(name: "apple", value: $0) }].compactMap { $0 }
        let reply = try await send("/hear?" + (query.percentEncodedQuery ?? ""), body: recording, timeout: 20)
        guard let text = reply["text"] as? String else { throw Failure(reply["error"] as? String ?? "the Mac sent no text") }
        return text
    }

    private func send(_ path: String, body: Data, timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: address + path) else { throw Failure("bad server address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure(reply["error"] as? String ?? "the Mac answered \(status)") }
        return reply
    }
}
