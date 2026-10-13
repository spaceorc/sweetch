import Foundation

/// `sweetch --rehear <dictation folder>…`: runs a stored dictation through today's pipeline — prefix,
/// listenings, settling — from its recording and the context saved beside it, and prints what each
/// step made of it and how long it took. Nothing is typed; the listenings' files go to `rehear/`
/// inside each folder. It is how prompt changes are checked against real recordings.
enum Rehear {
    static func run(_ dirs: [URL]) {
        for dir in dirs {
            print("\n=== \(dir.lastPathComponent)")
            let wav = dir.appendingPathComponent("recording.wav")
            guard FileManager.default.fileExists(atPath: wav.path), let context = gathered(from: dir) else {
                print("  (no recording or context)")
                continue
            }
            let before = json(dir.appendingPathComponent("session.json"))
            print("  app: \(context.app)  ·  then typed: \(before["inserted"] as? String ?? before["text"] as? String ?? "-")")
            let out = dir.appendingPathComponent("rehear", isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            let started = Date()
            let prefix = Prefix.build(from: context)
            let prefixSeconds = Date().timeIntervalSince(started)
            for (language, text) in prefix.spoken.sorted(by: { $0.key > $1.key }) { print("  prefix \(language): \(text)") }
            if let preceding = prefix.preceding { print("  preceding: \(preceding.suffix(120))") }

            let heardAt = Date()
            do {
                var apple: String?
                if #available(macOS 26.0, *) { apple = LivePreview.transcribe(file: wav) }
                guard let settled = try Hearing.hear(wav, dir: out, prepared: { (prefix, context, apple) }) else {
                    print("  nothing heard")
                    continue
                }
                for one in settled.versions.flatMap(\.members) {
                    let unsure = Hearing.uncertain(one.heard.words).map { "\($0.text) \(String(format: "%.2f", $0.probability))" }
                    print("  · \(one.kind.described)\(one.prefixed ? " + prefix" : ""): \(one.heard.text)"
                          + (unsure.isEmpty ? "" : "   [unsure: \(unsure.joined(separator: ", "))]"))
                }
                let s = settled.settlement ?? [:]
                if let skipped = s["skipped"] as? String { print("  model: skipped (\(skipped))") }
                if let reply = s["reply"] as? String, let reasoning = LLMJSON.string(reply, key: "reasoning") {
                    print("  model: \(reasoning)")
                }
                print("  → \(settled.text)")
                print(String(format: "  time: prefix %.2fs (while speaking) · after release %.2fs · model %.2fs",
                             prefixSeconds, Date().timeIntervalSince(heardAt), s["seconds"] as? Double ?? 0))
            } catch {
                print("  failed: \(error)")
            }
        }
    }

    /// The context as it was gathered, read back from `context.json`.
    private static func gathered(from dir: URL) -> ContextSnapshot.Gathered? {
        let c = json(dir.appendingPathComponent("context.json"))
        guard !c.isEmpty else { return nil }
        var before = c["text_before_cursor"] as? String
        if before == nil, let field = c["field"] as? [String: Any], let value = field["value"] as? String,
           let selection = field["selection"] as? [String: Any], let cursor = selection["location"] as? Int {
            // The saved value is a window around the cursor once the field is long; find the cursor in it.
            let ns = value as NSString
            let length = field["value_length"] as? Int ?? ns.length
            let start = length > ns.length ? max(0, min(cursor - ns.length * 3 / 4, length - ns.length)) : 0
            before = ns.substring(to: min(max(cursor - start, 0), ns.length))
        }
        return ContextSnapshot.Gathered(app: c["app"] as? String ?? "?",
                                        windowTitle: c["window_title"] as? String,
                                        textBeforeCursor: before,
                                        windowTexts: c["window_texts"] as? [String] ?? [],
                                        ocrText: c["ocr"] as? String)
    }

    private static func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
