import Foundation

/// The keyboard's log on the phone's disk until a Mac takes it: batches of events, one file each, in
/// the app group — so nothing is lost when no Mac is in reach, iOS stops the keyboard, or the phone
/// restarts, and the app can send them too when it reaches a Mac first. A batch keeps its id when
/// sent again; the Mac keeps it once. Before this (20 Oct 2026) the log lived only in the keyboard's
/// memory and went with it.
enum KeyLogSpool {
    /// Batches kept at most: past it the oldest go (about 50 MB of log).
    private static let limit = 200
    private static let lock = NSLock()

    static var dir: URL? {
        guard let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedState.group) else { return nil }
        let dir = group.appendingPathComponent("keylog", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Events, a batch of their own on disk. False with no app group (the caller keeps them).
    @discardableResult
    static func add(_ events: [[String: Any]]) -> Bool {
        guard !events.isEmpty, let dir else { return false }
        let lines = events.compactMap { event -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        // Named so they sort by when: the oldest are sent — and dropped — first.
        let name = String(format: "%013d-%@.jsonl", Int(Date().timeIntervalSince1970 * 1000), UUID().uuidString)
        lock.lock(); defer { lock.unlock() }
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
        let all = batches(in: dir)
        if all.count > limit { for old in all.prefix(all.count - limit) { try? FileManager.default.removeItem(at: old) } }
        return true
    }

    /// Sends the kept batches, oldest first, and forgets each one taken; stops at the first not.
    static func flush(_ deliver: ([[String: Any]], String) async -> Bool) async {
        guard let dir else { return }
        for file in batches(in: dir) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let events = text.split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }
            let id = file.deletingPathExtension().lastPathComponent
            if !events.isEmpty {
                let taken = await deliver(events, id)
                guard taken else { return }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// How many events wait to be sent — for the status line.
    static var waiting: Int {
        guard let dir else { return 0 }
        return batches(in: dir).count
    }

    private static func batches(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
