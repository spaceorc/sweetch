import AppKit

/// How the three devices stand, for the window: which build each runs against the one checked out
/// here, whether the Mac mini answers, when the iPhone's keyboard log last came, how the last sync
/// went. Gathered off the main thread; nothing here changes anything.
struct SystemStatus {
    struct Mini {
        var reachable = false
        var commit: String?
        /// Seconds since it last heard a dictation.
        var idle: Int?
    }

    struct Sync {
        var date: Date?
        var ok: Bool
        var line: String
    }

    /// This Mac's build, and the commit checked out where it was built from.
    var macCommit: String?
    var head: String?
    var mini = Mini()
    var phoneCommit: String?
    var phoneLog: Date?
    var sync: Sync?
    var keyboardWords: Date?
    var crashReport: URL?

    func isCurrent(_ commit: String?) -> Bool? {
        guard let commit, !commit.isEmpty, let head else { return nil }
        // Changes not committed (+) count as the same commit.
        let a = commit.trimmingCharacters(in: ["+"]), b = head.trimmingCharacters(in: ["+"])
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    /// The repository this build came from: the app sits in its `build/`.
    static var repo: URL { Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent() }

    static func gather() async -> SystemStatus {
        var s = SystemStatus()
        s.macCommit = Bundle.main.object(forInfoDictionaryKey: "SweetchCommit") as? String
        s.head = git(["describe", "--always", "--dirty=+"])
        async let mini = pingMini()
        let phone = phoneSeen()
        s.phoneCommit = phone.commit
        s.phoneLog = phone.last
        s.sync = lastSync()
        s.keyboardWords = (try? repo.appendingPathComponent("iOS/SweetchKeyboard/Lexicon.bin")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        s.mini = await mini
        return s
    }

    private static func git(_ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", repo.path] + args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return task.terminationStatus == 0 && !text.isEmpty ? text : nil
    }

    /// Its `/ping` (no token needed), over Tailscale or the home network, whichever answers first.
    private static func pingMini() async -> Mini {
        await withTaskGroup(of: Mini?.self) { group in
            for host in ["100.64.10.10", "ivans-mac-mini.local"] {
                group.addTask {
                    var request = URLRequest(url: URL(string: "http://\(host):8180/ping")!)
                    request.timeoutInterval = 3
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
                    let commit = json["commit"] as? String
                    return Mini(reachable: true, commit: commit?.isEmpty == false ? commit : nil, idle: json["idle"] as? Int)
                }
            }
            for await result in group { if let result { group.cancelAll(); return result } }
            return Mini()
        }
    }

    /// The iPhone keyboard's build, as its last `appear` says, and its last event.
    struct PhoneSeen: Codable {
        var commit: String?
        var last: Double?
    }

    private static let phoneDigests = LogDigests<PhoneSeen>("system-phone", version: 1)

    private static func phoneSeen() -> (commit: String?, last: Date?) {
        let dir = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var commit: String?, last: Double?
        // The newest days first; a day with no `appear` carrying a commit (an older build) goes on.
        for file in files.prefix(7) {
            let seen = phoneDigests.state(for: file, fresh: { PhoneSeen() }) { seen, text in
                for line in text.split(separator: "\n") {
                    if line.contains("\"e\":\"appear\""),
                       let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                       let c = e["commit"] as? String, !c.isEmpty { seen.commit = c }
                }
                if let tail = text.split(separator: "\n").last,
                   let e = (try? JSONSerialization.jsonObject(with: Data(tail.utf8))) as? [String: Any],
                   let t = e["t"] as? Double { seen.last = max(seen.last ?? 0, t) }
            }
            last = max(last ?? 0, seen.last ?? 0)
            if commit == nil { commit = seen.commit }
            if commit != nil { break }
        }
        phoneDigests.save()
        return (commit, last.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil })
    }

    /// The sync's log: "2026-10-24 00:15:01 synced", "… with errors", "… out of reach".
    private static func lastSync() -> Sync? {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/sweetch-sync.log")
        guard let line = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last.map(String.init) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = f.date(from: String(line.prefix(19)))
        let what = line.count > 20 ? String(line.dropFirst(20)) : line
        return Sync(date: date, ok: what == "synced", line: what)
    }
}
