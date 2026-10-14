import Foundation
import Network

/// Dictation for another device — the iPhone — over plain HTTP on the local network (or Tailscale):
/// the same listenings, prefix and settling as a hold of Space here, on this Mac's GPU.
///
/// A dictation is two requests, so the slow part of the context runs while the user speaks:
///
///     POST /context              JSON {app?, field_before?, screenshot? (PNG, base64)} → {id}
///         reads the screenshot and writes the prefix in the background
///     POST /hear?id=…&apple=…    the recording, in any format ffmpeg reads → {text, seconds, …}
///         `apple` is the phone's own live transcript, when it has one; `id` may be left out
///     GET  /next?after=…&wait=…  → {seq, text}: the next text heard, waiting up to `wait` s (≤ 25) for it
///         the keyboard's: it types each text once, as soon as it's heard
///     POST /field                JSON {text} — what the field holds before the cursor, from the
///         keyboard; the next context takes it
///     GET  /ping                 → {ok}
///
/// Every request but /ping carries `Authorization: Bearer <token>`; the token is made on first start
/// and kept in `server-token` in sweetch's Application Support folder. Each dictation is stored with
/// the Mac's own, so the Dictations window, `--rehear` and the tuning cycles see them too.
final class DictationServer {
    static let port: NWEndpoint.Port = 8180

    static let token: String = {
        let url = AppSupport.dir.appendingPathComponent("server-token")
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let made = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }.joined().prefix(40)
        try? String(made).write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return String(made)
    }()

    /// A dictation whose context came in and whose recording hasn't yet.
    private final class Pending {
        let dir: URL
        let startedAt = Date()
        let ready = DispatchGroup()
        var context: ContextSnapshot.Gathered?
        var prefix: Prefix?

        init(dir: URL) { self.dir = dir }
    }

    private let queue = DispatchQueue(label: "sweetch.server", attributes: .concurrent)
    private let lock = NSLock()
    private var listener: NWListener?
    private var pending: [String: Pending] = [:]
    /// Dictations being heard, and when the last one was: an update waits for a quiet moment
    /// (`/ping` tells it, see Tools/mini/update.sh).
    private var hearing = 0
    private var lastDictation = Date.distantPast
    /// The field the keyboard last saw, for the next context.
    private var field: (text: String, at: Date)?

    /// The last text heard, numbered by when (ms) so the keyboard types each once — across restarts
    /// too. Guarded by `heard`, which wakes the keyboard's waiting request.
    private let heard = NSCondition()
    private var latest: (seq: Int, text: String)?

    private static let maxBody = 50 << 20

    var isRunning: Bool { lock.withLock { listener != nil } }

    func start() {
        guard !isRunning else { return }
        do {
            let listener = try NWListener(using: .tcp, on: Self.port)
            listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: log.info("dictation server: listening on :\(Self.port.rawValue, privacy: .public)")
                case .failed(let error): log.error("dictation server: \(error.localizedDescription, privacy: .public)")
                default: break
                }
            }
            listener.start(queue: queue)
            lock.withLock { self.listener = listener }
            _ = Self.token
            Whisper.warmUp()
        } catch {
            log.error("dictation server: couldn't listen: \(error.localizedDescription, privacy: .public)")
        }
    }

    func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
        log.info("dictation server: stopped")
    }

    // MARK: - HTTP

    private struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]   // names lowercased
        let body: Data
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, into: Data())
    }

    /// Reads until the headers and `Content-Length` bytes of body are in.
    private func read(_ connection: NWConnection, into buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                return self.respond(to: request, on: connection)
            }
            if error != nil || complete || buffer.count > Self.maxBody {
                return connection.cancel()
            }
            self.read(connection, into: buffer)
        }
    }

    /// The request, once all of it is in `buffer`; nil while more is to come.
    private static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        let components = URLComponents(string: String(start[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(start[0]), path: components?.path ?? "/", query: query,
                       headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let (status, reply): (Int, [String: Any])
        if request.path == "/ping" {
            let idle = lock.withLock { hearing > 0 ? 0 : Date().timeIntervalSince(lastDictation) }
            (status, reply) = (200, ["ok": true, "idle": Int(min(idle, 86_400))])
        } else if request.headers["authorization"] != "Bearer \(Self.token)" {
            (status, reply) = (401, ["error": "unauthorized"])
        } else {
            switch (request.method, request.path) {
            case ("POST", "/context"):
                lock.withLock { lastDictation = Date() }
                (status, reply) = context(request)
            case ("POST", "/hear"):
                lock.withLock { hearing += 1 }
                (status, reply) = hear(request)
                lock.withLock {
                    hearing -= 1
                    lastDictation = Date()
                }
            case ("GET", "/next"):
                (status, reply) = next(after: Int(request.query["after"] ?? "") ?? 0,
                                       wait: min(Double(request.query["wait"] ?? "") ?? 25, 25))
            case ("POST", "/field"): (status, reply) = noteField(request)
            default: (status, reply) = (404, ["error": "no such endpoint"])
            }
        }
        let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - Dictation

    private func context(_ request: Request) -> (Int, [String: Any]) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return (400, ["error": "expected a JSON body"])
        }
        let id = UUID().uuidString
        let entry = Pending(dir: DictationStore.newSessionDir())
        lock.withLock {
            pending = pending.filter { Date().timeIntervalSince($0.value.startedAt) < 300 }
            pending[id] = entry
        }
        let app = json["app"] as? String
        let fieldBefore = json["field_before"] as? String ?? lock.withLock {
            field.flatMap { Date().timeIntervalSince($0.at) < 120 ? $0.text : nil }
        }
        let screenshot = (json["screenshot"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }

        entry.ready.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { entry.ready.leave() }
            let started = Date()
            var saved: [String: Any] = ["app": app ?? Prefix.unknownApp, "device": "iPhone"]
            if let fieldBefore { saved["text_before_cursor"] = String(fieldBefore.suffix(2000)) }
            var ocr: String?
            if let screenshot {
                let png = entry.dir.appendingPathComponent("window.png")
                try? screenshot.write(to: png)
                saved["screenshot"] = png.lastPathComponent
                let ocrStarted = Date()
                ocr = ContextSnapshot.readText(in: png)
                saved["ocr"] = ocr
                saved["ocr_seconds"] = Date().timeIntervalSince(ocrStarted)
            }
            saved["seconds"] = Date().timeIntervalSince(started)
            DictationStore.write(saved, to: entry.dir.appendingPathComponent("context.json"))
            let gathered = ContextSnapshot.Gathered(app: app ?? Prefix.unknownApp, windowTitle: nil, textBeforeCursor: fieldBefore,
                                                    windowTexts: [], ocrText: ocr)
            entry.context = gathered
            let gatheredSeconds = Date().timeIntervalSince(started)
            let prefix = Prefix.build(from: gathered)
            entry.prefix = prefix
            DictationStore.write([
                "spoken": prefix.spoken, "preceding": prefix.preceding ?? NSNull(),
                "context_seconds": gatheredSeconds, "seconds": Date().timeIntervalSince(started),
            ], to: entry.dir.appendingPathComponent("prefix.json"))
        }
        return (200, ["id": id])
    }

    private func hear(_ request: Request) -> (Int, [String: Any]) {
        guard !request.body.isEmpty else { return (400, ["error": "no recording"]) }
        let entry = request.query["id"].flatMap { id in lock.withLock { pending.removeValue(forKey: id) } }
            ?? {
                // No context came: an empty one, so the dictation can still be heard again offline.
                let entry = Pending(dir: DictationStore.newSessionDir())
                DictationStore.write(["app": "iPhone", "device": "iPhone"], to: entry.dir.appendingPathComponent("context.json"))
                return entry
            }()
        let apple = request.query["apple"].flatMap { $0.isEmpty ? nil : $0 }
        let started = Date()
        var record: [String: Any] = [
            "device": "iPhone",
            "started_at": DictationStore.stamp(entry.startedAt),
            "app": entry.context?.app ?? "iPhone",
        ]
        defer { DictationStore.write(record, to: entry.dir.appendingPathComponent("session.json")) }
        do {
            let upload = entry.dir.appendingPathComponent("recording.upload")
            try request.body.write(to: upload)
            let wav = entry.dir.appendingPathComponent("recording.wav")
            try Whisper.normalise(upload, to: wav)
            try? FileManager.default.removeItem(at: upload)
            let settled = try Hearing.hear(wav, dir: entry.dir) {
                _ = entry.ready.wait(timeout: .now() + 1.5)
                return (entry.prefix, entry.context, apple)
            }
            record["app"] = entry.context?.app ?? "iPhone"
            record["seconds"] = Date().timeIntervalSince(started)
            if let apple { record["apple"] = apple }
            guard let settled else {
                record["text"] = ""
                return (200, ["text": "", "seconds": record["seconds"] ?? 0])
            }
            record["listenings"] = settled.versions.flatMap(\.members).map(\.record)
            record["versions"] = settled.versions.map(\.text)
            record["settlement"] = settled.settlement ?? NSNull()
            record["text"] = settled.text
            if !settled.text.isEmpty {
                heard.withLock { latest = (Int(Date().timeIntervalSince1970 * 1000), settled.text) }
                heard.broadcast()
            }
            log.info("dictation server: heard '\(settled.text, privacy: .public)'")
            return (200, ["text": settled.text, "seconds": record["seconds"] ?? 0, "versions": settled.versions.map(\.text)])
        } catch {
            record["error"] = String(describing: error)
            log.error("dictation server: \(String(describing: error), privacy: .public)")
            return (500, ["error": String(describing: error)])
        }
    }

    // MARK: - The keyboard

    private func next(after: Int, wait: TimeInterval) -> (Int, [String: Any]) {
        let deadline = Date().addingTimeInterval(wait)
        heard.lock()
        defer { heard.unlock() }
        while (latest?.seq ?? 0) <= after, heard.wait(until: deadline) {}
        guard let latest, latest.seq > after else { return (200, ["seq": after]) }
        return (200, ["seq": latest.seq, "text": latest.text])
    }

    private func noteField(_ request: Request) -> (Int, [String: Any]) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String else { return (400, ["error": "expected {text}"]) }
        lock.withLock { field = (String(text.suffix(2000)), Date()) }
        return (200, ["ok": true])
    }
}
