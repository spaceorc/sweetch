import Foundation

/// The dictations the phone heard by itself (Documents/dictation, PhonePipeline): sent to a Mac as
/// soon as one answers — kept there as the Macs keep theirs, synced on, heard again on asking —
/// and shown in the history meanwhile; once sent, gone from the phone.
enum PhoneDictations {
    static var dir: URL { URL.documentsDirectory.appendingPathComponent("dictation", isDirectory: true) }

    /// Each kept dictation's folder, newest first; `sent`: a Mac has it.
    static func folders() -> [(url: URL, sent: Bool)] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { ($0, FileManager.default.fileExists(atPath: $0.appendingPathComponent(".sent").path)) }
    }

    /// The ones no Mac has yet, as the history lists them.
    static func unsent() -> [[String: Any]] {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return folders().filter { !$0.sent }.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.url.appendingPathComponent("session.json")),
                  let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return ["id": folder.url.lastPathComponent, "t": f.date(from: folder.url.lastPathComponent)?.timeIntervalSince1970 ?? 0,
                    "text": s["text"] as? String ?? "", "app": "iPhone", "device": "iPhone",
                    "heard_on": s["heard_on"] as? String ?? "phone", "recording": true, "local": true]
        }
    }

    private static let gate = Gate()

    /// Sends what no Mac has yet to the Mac that answers. Once at a time.
    static func upload() async {
        guard await gate.enter() else { return }
        defer { Task { await gate.leave() } }
        let pending = folders().filter { !$0.sent }
        guard !pending.isEmpty, let mac = await Server.reachable() else { return }
        for folder in pending {
            // Once a Mac has it, the phone needn't keep it: the Macs keep it and the history shows it.
            if (try? await send(folder.url, to: mac)) == true { try? FileManager.default.removeItem(at: folder.url) }
        }
    }

    /// One folder to the Mac; true once it has it.
    static func send(_ folder: URL, to mac: Server) async throws -> Bool {
        var files: [String: String] = [:]
        for name in ["session.json", "context.json", "recording.wav", "window.png"] {
            if let data = try? Data(contentsOf: folder.appendingPathComponent(name)) { files[name] = data.base64EncodedString() }
        }
        let body = try JSONSerialization.data(withJSONObject: ["files": files])
        let reply = try await mac.post("/phone-dictation?id=\(folder.lastPathComponent)", body: body, timeout: 60)
        return reply["ok"] as? Bool == true
    }

    private actor Gate {
        var busy = false
        func enter() -> Bool { if busy { return false }; busy = true; return true }
        func leave() { busy = false }
    }
}
