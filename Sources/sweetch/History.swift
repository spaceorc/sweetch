import Foundation

/// Append-only log of correction/revert events (JSON lines) — the raw behavioral statistics
/// that feed the glossary distiller and the "show history" view. Local file only.
enum History {
    struct Event: Codable {
        let ts: String
        let kind: String        // "correct" | "revert"
        let original: String
        let corrected: String
        let app: String?
    }

    static func record(kind: String, original: String, corrected: String, app: String?) {
        let ev = Event(ts: ISO8601DateFormatter().string(from: Date()),
                       kind: kind, original: original, corrected: corrected, app: app)
        guard let data = try? JSONEncoder().encode(ev),
              let json = String(data: data, encoding: .utf8) else { return }
        append(json + "\n")
    }

    /// Most recent lines (bounded) as raw JSONL — what we hand to the distiller.
    static func recentJSONL(maxLines: Int = 400) -> String {
        guard let s = try? String(contentsOf: AppSupport.history, encoding: .utf8) else { return "" }
        return s.split(whereSeparator: \.isNewline).suffix(maxLines).joined(separator: "\n")
    }

    private static func append(_ line: String) {
        let url = AppSupport.history
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(data)
        } else {
            try? data.write(to: url)
        }
    }
}
