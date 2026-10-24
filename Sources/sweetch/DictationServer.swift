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
    /// The keyboard log's batches already kept — on disk too (`keyboard/.batches`): a batch can come
    /// twice a day apart, pulled off the phone with `make phone-logs` and later sent by the phone.
    private lazy var keyboardBatches: Set<String> = Set(((try? String(contentsOf: Self.batchesFile, encoding: .utf8)) ?? "")
        .split(separator: "\n").map(String.init))
    private static var batchesFile: URL { AppSupport.dir.appendingPathComponent("keyboard/.batches") }
    private var lastDictation = Date.distantPast
    /// The field the keyboard last saw, for the next context.
    private var field: (text: String, at: Date)?

    /// The last text heard, numbered by when (ms) so the keyboard types each once — across restarts
    /// too. Guarded by `heard`, which wakes the keyboard's waiting request.
    private let heard = NSCondition()
    /// The last text heard for the iPhone, with its dictation's folder name — the id the keyboard
    /// logs it under.
    private var latest: (seq: Int, text: String, id: String)?

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
            (status, reply) = (200, ["ok": true, "idle": Int(min(idle, 86_400)),
                                     "commit": Bundle.main.object(forInfoDictionaryKey: "SweetchCommit") as? String ?? ""])
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
            case ("POST", "/keyboard-log"): (status, reply) = keepKeyboardLog(request)
            // The model's credentials and the user's name, for the iPhone to hear by itself when no
            // Mac answers. Kept there in its Keychain; asked for with the server's token.
            // How well sweetch does, in numbers without text, for the app to show.
            case ("GET", "/metrics"): (status, reply) = (200, Stats.currentMetrics())
            // What the numbers say about the hands and the voice: heat maps, offsets, confusions.
            case ("GET", "/insights"): (status, reply) = (200, Stats.currentInsights())
            // The dictations, newest first — what was said, into what, on which device — for the
            // iPhone app's history.
            case ("GET", "/dictations"): (status, reply) = (200, ["dictations": Self.dictations(limit: Int(request.query["limit"] ?? "") ?? 200)])
            // A dictation the iPhone heard by itself, no Mac in reach: its folder, kept here as the
            // Macs keep theirs (and synced on), to be heard again.
            case ("POST", "/phone-dictation"): (status, reply) = keepPhoneDictation(request)
            // A dictation heard again from its recording, today's way.
            case ("POST", "/hear-again"): (status, reply) = hearAgain(request)
            case ("GET", "/llm-config"):
                (status, reply) = LLMClient.credentialsText.map { (200, ["env": $0, "user_name": NSFullUserName()]) }
                    ?? (404, ["error": "no credentials here"])
            default: (status, reply) = (404, ["error": "no such endpoint"])
            }
        }
        let body = (try? JSONSerialization.data(withJSONObject: reply, options: [.withoutEscapingSlashes])) ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A dictation folder's name as the phone gives it: a timestamp, nothing to climb out with.
    private static func folder(_ id: String?) -> URL? {
        guard let id, id.range(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}-\d{3}$"#, options: .regularExpression) != nil else { return nil }
        return DictationStore.dir.appendingPathComponent(id, isDirectory: true)
    }

    /// Body: {"files": {name: base64}} — session.json, context.json, recording.wav, window.png.
    private func keepPhoneDictation(_ request: Request) -> (Int, [String: Any]) {
        guard let dir = Self.folder(request.query["id"]),
              let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let files = body["files"] as? [String: String] else { return (400, ["error": "bad dictation"]) }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path) { return (200, ["ok": true, "kept": false]) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, base64) in files where ["session.json", "context.json", "recording.wav", "window.png"].contains(name) {
            if let data = Data(base64Encoded: base64) { try? data.write(to: dir.appendingPathComponent(name)) }
        }
        log.info("phone dictation kept: \(dir.lastPathComponent, privacy: .public)")
        DispatchQueue.main.async { NotificationCenter.default.post(name: DictationStore.changed, object: dir) }
        return (200, ["ok": true, "kept": true])
    }

    private func hearAgain(_ request: Request) -> (Int, [String: Any]) {
        guard let dir = Self.folder(request.query["id"]) else { return (400, ["error": "bad id"]) }
        do {
            guard let text = try Rehear.again(dir) else { return (404, ["error": "no recording of it here"]) }
            DispatchQueue.main.async { NotificationCenter.default.post(name: DictationStore.changed, object: dir) }
            return (200, ["text": text])
        } catch {
            return (500, ["error": "\(error)"])
        }
    }

    /// The last `limit` dictations that typed something, as the iPhone's history shows them.
    static func dictations(limit: Int) -> [[String: Any]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        var list: [[String: Any]] = []
        for dir in dirs {
            guard list.count < min(limit, 1000) else { break }
            let entry = DictationsWindow.Entry(dir: dir, date: f.date(from: dir.lastPathComponent) ?? .distantPast, session: [:])
            let session = entry.json("session.json")
            guard !session.isEmpty, session["cancelled"] as? Bool != true, session["error"] == nil else { continue }
            // Dictated into sweetch's talk about a dictation: part of that talk, not one of its own.
            if let context = (try? Data(contentsOf: dir.appendingPathComponent("context.json")))
                .flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
               (context["keyboard"] as? [String: Any])?["sweetch_screen"] != nil { continue }
            let full = DictationsWindow.Entry(dir: dir, date: entry.date, session: session)
            let text = full.said
            guard !text.isEmpty, text != full.summary || session["inserted"] != nil || session["text"] != nil else { continue }
            var item: [String: Any] = ["id": dir.lastPathComponent, "t": entry.date.timeIntervalSince1970, "text": text,
                                       "app": full.app, "device": session["device"] as? String ?? "Mac"]
            if let seconds = session["seconds"] as? Double { item["seconds"] = seconds }
            if let to = session["handoff"] as? String { item["handoff"] = to }
            item["heard_on"] = session["heard_on"] as? String ?? "mac"
            // The model meant to settle it didn't — too slow, failed, no credentials, or its answer
            // refused: typed as whisper heard it. (Skipped is settled: every listening agreed.)
            if let s = session["settlement"] as? [String: Any], s["skipped"] == nil,
               s["timed_out"] != nil || s["reply"] == nil || s["reply"] is NSNull || s["overruled"] != nil { item["raw"] = true }
            item["recording"] = FileManager.default.fileExists(atPath: dir.appendingPathComponent("recording.wav").path)
            if let before = session["before"] as? [[String: Any]], let first = before.first?["text"] as? String { item["before"] = first }
            list.append(item)
        }
        return list
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
        // What the keyboard knew, when its microphone opened the dictation.
        let keyboard = json["keyboard"] as? [String: Any]
        let fieldBefore = json["field_before"] as? String ?? (keyboard?["field_before"] as? String) ?? lock.withLock {
            field.flatMap { Date().timeIntervalSince($0.at) < 120 ? $0.text : nil }
        }
        let screenshot = (json["screenshot"] as? String).flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }

        entry.ready.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { entry.ready.leave() }
            let started = Date()
            var saved: [String: Any] = ["app": app ?? Prefix.unknownApp, "device": "iPhone"]
            if let fieldBefore { saved["text_before_cursor"] = String(fieldBefore.suffix(2000)) }
            if let keyboard { saved["keyboard"] = keyboard }
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
            // Dictated into sweetch's own talk about a dictation: that dictation is what's on screen.
            var windowTexts: [String] = []
            var title: String?
            if let screen = keyboard?["sweetch_screen"] as? [String: Any], screen["screen"] as? String == "dictation-chat" {
                title = "Sweetch — a chat about a dictation, asking for a version of it or about it"
                if let about = screen["about"] as? String { windowTexts.append(about) }
                if let last = screen["last"] as? String { windowTexts.append(last) }
            }
            let gathered = ContextSnapshot.Gathered(app: app ?? Prefix.unknownApp, windowTitle: title, textBeforeCursor: fieldBefore,
                                                    windowTexts: windowTexts, ocrText: ocr, keyboard: keyboard.map(ContextSnapshot.keyboard))
            if let title {
                // Kept with the rest, so hearing it again has it too.
                saved["window_title"] = title
                saved["window_texts"] = windowTexts
                DictationStore.write(saved, to: entry.dir.appendingPathComponent("context.json"))
            }
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
                heard.withLock { latest = (Int(Date().timeIntervalSince1970 * 1000), settled.text, entry.dir.lastPathComponent) }
                heard.broadcast()
            }
            log.info("dictation server: heard '\(shown(settled.text), privacy: .public)'")
            return (200, ["text": settled.text, "seconds": record["seconds"] ?? 0, "versions": settled.versions.map(\.text),
                          "id": entry.dir.lastPathComponent])
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
        return (200, ["seq": latest.seq, "text": latest.text, "id": latest.id])
    }

    private func noteField(_ request: Request) -> (Int, [String: Any]) {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let text = json["text"] as? String else { return (400, ["error": "expected {text}"]) }
        lock.withLock { field = (String(text.suffix(2000)), Date()) }
        return (200, ["ok": true])
    }

    /// The iPhone keyboard's events (its KeyLog), one JSON line each, in a file per day and per Mac
    /// — the Macs sync `keyboard/` both ways, and two Macs appending to one file would lose lines.
    private func keepKeyboardLog(_ request: Request) -> (Int, [String: Any]) {
        // {batch, events}: a batch the keyboard sent again — its answer lost on the way — is kept once.
        let json = try? JSONSerialization.jsonObject(with: request.body)
        guard let events = (json as? [String: Any])?["events"] as? [[String: Any]] ?? json as? [[String: Any]] else {
            return (400, ["error": "expected {batch, events}"])
        }
        if let batch = (json as? [String: Any])?["batch"] as? String {
            let seen = lock.withLock {
                if keyboardBatches.contains(batch) { return true }
                keyboardBatches.insert(batch)
                try? FileManager.default.createDirectory(at: Self.batchesFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: Self.batchesFile) {
                    handle.seekToEndOfFile(); handle.write(Data((batch + "\n").utf8)); try? handle.close()
                } else {
                    try? Data((batch + "\n").utf8).write(to: Self.batchesFile)
                }
                return false
            }
            if seen { return (200, ["ok": true, "kept": 0, "duplicate": true]) }
        }
        let dir = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = String(DictationStore.stamp(Date()).prefix(10))
        let host = (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac").lowercased()
        let url = dir.appendingPathComponent("\(day)-\(host).jsonl")
        var lines = Data()
        for event in events {
            guard let line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
            lines += line + Data("\n".utf8)
        }
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(lines)
                try? handle.close()
            } else {
                try? lines.write(to: url)
            }
        }
        log.info("keyboard log: \(events.count, privacy: .public) events kept")
        return (200, ["ok": true, "kept": events.count])
    }
}
