import Foundation

/// The Mac's account of what the models cost (LLMUsage): a line per call in
/// `llm-usage/<day>-<host>.jsonl`, synced between the Macs (Tools/mini/sync.sh) — a file per Mac,
/// so two never write one.
enum LLMUsageLog {
    private static let lock = NSLock()
    private static let host = (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac").lowercased()

    static var dir: URL { AppSupport.dir.appendingPathComponent("llm-usage", isDirectory: true) }

    static func append(_ record: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("\(f.string(from: Date()))-\(host).jsonl")
        lock.withLock {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(line); try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
