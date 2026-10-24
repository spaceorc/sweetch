import Foundation

/// sweetch on a Mac: see DictationServer.swift there. Several Macs, in the order they're preferred
/// — the MacBook, whose whisper is twice as fast, then the Mac mini at home, which is always on —
/// each reached over Tailscale from anywhere, or on the local network when Tailscale is off (iOS
/// runs one VPN at a time, and the work one wins).
struct Server {
    var address: String
    var token: String
    /// Which Mac: the first of its addresses.
    var mac: String

    static let addressKey = "serverAddress"
    static let tokenKey = "serverToken"
    /// One Mac per line, preferred first; a Mac's addresses comma-separated, tried at once.
    static let defaultAddresses = """
        http://100.85.3.88:8180, http://ivans-macbook-pro.local:8180
        http://100.64.10.10:8180, http://ivans-mac-mini.local:8180
        """
    /// What earlier builds kept, which meant only the MacBook.
    private static let formerDefaults = [
        "http://100.85.3.88:8180", "http://100.85.3.88:8180, http://ivans-macbook-pro.local:8180",
        // The Mac mini's Tailscale address used to be inside the work VPN's range.
        "http://100.85.3.88:8180, http://ivans-macbook-pro.local:8180\nhttp://100.102.243.87:8180, http://ivans-mac-mini.local:8180",
    ]

    /// A Mac that didn't answer is passed over this long: a closed MacBook costs one wait, not one
    /// per dictation, and the phone doesn't flit between Macs.
    static let downFor: TimeInterval = 300
    private static let downKey = "serverDownUntil"

    /// Put in the build from the Mac's `server-token` (see `make phone`), so neither the app nor the
    /// keyboard needs it typed in; the app's setting overrides it.
    static var builtInToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "SweetchToken") as? String) ?? ""
    }

    private static var token: String {
        UserDefaults.standard.string(forKey: tokenKey).flatMap { $0.isEmpty ? nil : $0 } ?? builtInToken
    }

    /// The Macs, preferred first, each by its addresses.
    static var macs: [[String]] {
        var saved = UserDefaults.standard.string(forKey: addressKey) ?? defaultAddresses
        if formerDefaults.contains(saved.trimmingCharacters(in: .whitespacesAndNewlines)) { saved = defaultAddresses }
        return saved.split(whereSeparator: \.isNewline).map { line in
            line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
    }

    /// The app on this phone (PhoneServer): what it heard itself, for the keyboard.
    static let thisPhone = "http://127.0.0.1:8181"

    /// A Mac's name for showing: its host on the local network.
    static func name(of mac: String) -> String {
        let hosts = macs.first { $0.first == mac }?.compactMap { URL(string: $0)?.host } ?? []
        let host = hosts.first { $0.hasSuffix(".local") } ?? hosts.first ?? mac
        if mac == thisPhone { return "iPhone" }
        let short = host.replacingOccurrences(of: ".local", with: "").replacingOccurrences(of: "ivans-", with: "")
        // As people say them: "macbook-pro" is a MacBook, "mac-mini" a Mac mini.
        if short.contains("macbook") { return "MacBook" }
        if short.contains("mini") { return "Mac mini" }
        return short
    }

    /// The preferred Mac that answers, passing over those that didn't lately; nil when none does.
    static func reachable() async -> Server? {
        let macs = Self.macs
        let now = Date().timeIntervalSince1970
        let down = UserDefaults.standard.dictionary(forKey: downKey) as? [String: Double] ?? [:]
        var asked = macs.filter { (down[$0[0]] ?? 0) <= now }
        if asked.isEmpty { asked = macs }   // all passed over: ask them all again
        // Each answer as it comes: once every Mac preferred to one that answered has failed, that one
        // is it — no waiting on the less preferred.
        let chosen = await withTaskGroup(of: (Int, Server?).self) { group -> Server? in
            for (rank, addresses) in asked.enumerated() {
                group.addTask { (rank, await answering(addresses)) }
            }
            var answers: [Int: Server?] = [:]
            for await (rank, server) in group {
                answers[rank] = server
                if server == nil { markDown(asked[rank][0]) }
                for preferred in asked.indices {
                    guard let answer = answers[preferred] else { break }   // not in yet: wait for it
                    if let answer {
                        group.cancelAll()
                        return answer
                    }
                }
            }
            return nil
        }
        if let chosen { markUp(chosen.mac) }
        return chosen
    }

    /// The first of a Mac's addresses to answer: they're all the same Mac.
    static func answering(_ addresses: [String]) async -> Server? {
        let token = Self.token
        return await withTaskGroup(of: Server?.self) { group -> Server? in
            for address in addresses {
                group.addTask {
                    let server = Server(address: address, token: token, mac: addresses[0])
                    return await server.ping() ? server : nil
                }
            }
            for await server in group {
                if let server {
                    group.cancelAll()
                    return server
                }
            }
            return nil
        }
    }

    /// This Mac failed: the next dictation goes elsewhere for a while.
    static func markDown(_ mac: String) {
        var down = UserDefaults.standard.dictionary(forKey: downKey) as? [String: Double] ?? [:]
        down[mac] = Date().timeIntervalSince1970 + downFor
        UserDefaults.standard.set(down, forKey: downKey)
    }

    private static func markUp(_ mac: String) {
        var down = UserDefaults.standard.dictionary(forKey: downKey) as? [String: Double] ?? [:]
        guard down.removeValue(forKey: mac) != nil else { return }
        UserDefaults.standard.set(down, forKey: downKey)
    }

    func ping() async -> Bool {
        guard let url = URL(string: address + "/ping") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    /// Hands over what's on screen; the Mac reads it while the user speaks. Returns the id the
    /// recording goes with.
    func context(screenshot: Data?, fieldBefore: String?, keyboard: [String: Any]? = nil) async throws -> String {
        var body: [String: Any] = [:]
        if let screenshot { body["screenshot"] = screenshot.base64EncodedString() }
        if let fieldBefore { body["field_before"] = fieldBefore }
        if let keyboard { body["keyboard"] = keyboard }
        let reply = try await send("/context", body: try JSONSerialization.data(withJSONObject: body), timeout: 10)
        guard let id = reply["id"] as? String else { throw Failure("the Mac gave no id") }
        return id
    }

    /// The next text the Mac hears after `seq`, waiting up to `wait` seconds (at most 25) for it.
    /// `id`: the dictation's folder where it was heard.
    func next(after seq: Int, wait: Int) async throws -> (seq: Int, text: String?, id: String?) {
        let reply = try await get("/next?after=\(seq)&wait=\(wait)", timeout: TimeInterval(wait) + 5)
        return (reply["seq"] as? Int ?? seq, reply["text"] as? String, (reply["id"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// What the field holds before the cursor, for the next dictation's prefix.
    func noteField(_ text: String) async {
        _ = try? await send("/field", body: JSONSerialization.data(withJSONObject: ["text": text]), timeout: 3)
    }

    /// The keyboard's events, for the Mac to keep (see KeyLog). True when it took them.
    func keyboardLog(_ events: [[String: Any]], batch: String) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: ["batch": batch, "events": events]) else { return true }
        return (try? await send("/keyboard-log", body: body, timeout: 10)) != nil
    }

    /// The model's credentials and the user's name, for the phone to hear by itself (see
    /// PhonePipeline).
    /// How well sweetch does, counted on the Mac without any text (see the Mac's Metrics).
    func metrics() async throws -> [String: Any] {
        try await get("/metrics", timeout: 20)
    }

    /// What the numbers say about the hands and the voice (see the Mac's Insights).
    func insights() async throws -> [String: Any] {
        try await get("/insights", timeout: 60)
    }

    /// The dictations, newest first (see the Mac's DictationServer.dictations).
    func dictations(limit: Int = 200) async throws -> [[String: Any]] {
        try await get("/dictations?limit=\(limit)", timeout: 15)["dictations"] as? [[String: Any]] ?? []
    }

    func llmConfig() async throws -> (env: String, userName: String) {
        let reply = try await get("/llm-config", timeout: 5)
        guard let env = reply["env"] as? String else { throw Failure("no credentials from the Mac") }
        return (env, reply["user_name"] as? String ?? "")
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

    func post(_ path: String, body: Data, timeout: TimeInterval) async throws -> [String: Any] {
        try await send(path, body: body, timeout: timeout)
    }

    /// A dictation heard again on the Mac, from its recording: the new text.
    func hearAgain(_ id: String) async throws -> String {
        let reply = try await send("/hear-again?id=\(id)", body: Data(), timeout: 180)
        guard let text = reply["text"] as? String else { throw Failure(reply["error"] as? String ?? "not heard") }
        return text
    }

    private func get(_ path: String, timeout: TimeInterval) async throws -> [String: Any] {
        try await send(path, body: nil, timeout: timeout)
    }

    private func send(_ path: String, body: Data?, timeout: TimeInterval) async throws -> [String: Any] {
        guard let url = URL(string: address + path) else { throw Failure("bad server address") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
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

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
