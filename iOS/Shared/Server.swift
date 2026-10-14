import Foundation

/// sweetch on the Mac: see DictationServer.swift there. Reached over Tailscale from anywhere, or
/// on the local network when Tailscale is off — iOS runs one VPN at a time, and the work one wins.
struct Server {
    var address: String
    var token: String

    static let addressKey = "serverAddress"
    static let tokenKey = "serverToken"
    /// Tried in order; the setting holds them comma-separated.
    static let defaultAddresses = "http://100.85.3.88:8180, http://ivans-macbook-pro.local:8180"

    /// Put in the build from the Mac's `server-token` (see `make phone`), so neither the app nor the
    /// keyboard needs it typed in; the app's setting overrides it.
    static var builtInToken: String {
        (Bundle.main.object(forInfoDictionaryKey: "SweetchToken") as? String) ?? ""
    }

    /// The first address that answers, all asked at once; nil when none does.
    static func reachable() async -> Server? {
        let defaults = UserDefaults.standard
        let token = defaults.string(forKey: tokenKey).flatMap { $0.isEmpty ? nil : $0 } ?? builtInToken
        // The first build kept one address; that one is in the defaults now.
        var saved = defaults.string(forKey: addressKey) ?? defaultAddresses
        if saved == "http://100.85.3.88:8180" { saved = defaultAddresses }
        let addresses = saved
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let answered = await withTaskGroup(of: (Int, Bool).self) { group in
            for (i, address) in addresses.enumerated() {
                group.addTask { (i, await Server(address: address, token: token).ping()) }
            }
            var answered: [Int] = []
            for await (i, ok) in group where ok { answered.append(i) }
            return answered
        }
        return answered.min().map { Server(address: addresses[$0], token: token) }
    }

    func ping() async -> Bool {
        guard let url = URL(string: address + "/ping") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
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

    /// The next text the Mac hears after `seq`, waiting up to `wait` seconds (at most 25) for it.
    func next(after seq: Int, wait: Int) async throws -> (seq: Int, text: String?) {
        let reply = try await get("/next?after=\(seq)&wait=\(wait)", timeout: TimeInterval(wait) + 5)
        return (reply["seq"] as? Int ?? seq, reply["text"] as? String)
    }

    /// What the field holds before the cursor and the app it's in, for the next dictation's prefix.
    /// Tells the Mac the field; answers which app the Mac knows the keyboard's process to be.
    @discardableResult
    func noteField(_ text: String, app: String?, pid: Int32?) async -> String? {
        var body: [String: Any] = ["text": text]
        if let app { body["app"] = app }
        if let pid { body["pid"] = Int(pid) }
        let reply = try? await send("/field", body: JSONSerialization.data(withJSONObject: body), timeout: 3)
        return reply?["app"] as? String
    }

    /// A line for the Mac's `phone.log`: how things went where the phone can't be watched.
    func log(_ line: String) async {
        _ = try? await send("/log", body: Data(line.utf8), timeout: 3)
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

/// The apps dictated into most, by bundle id: their names for the prefix, and how to go back to
/// them — iOS has no "back" an app can press, but these open by their URL schemes.
enum HostApp {
    static let known: [String: (name: String, scheme: String)] = [
        "ph.telegra.Telegraph": ("Telegram", "tg://"),
        "com.tinyspeck.chatlyio": ("Slack", "slack://open"),
        "net.whatsapp.WhatsApp": ("WhatsApp", "whatsapp://"),
        "com.apple.MobileSMS": ("Messages", "sms://"),
        "com.apple.mobilenotes": ("Notes", "mobilenotes://"),
        "com.apple.mobilesafari": ("Safari", "x-web-search://"),
    ]

    /// How to open an app named by its bundle id or by the name the Mac gave it.
    static func scheme(for app: String) -> String? {
        known[app]?.scheme ?? known.values.first { $0.name.caseInsensitiveCompare(app) == .orderedSame }?.scheme
    }

    static func name(_ bundleID: String) -> String {
        known[bundleID]?.name ?? bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
