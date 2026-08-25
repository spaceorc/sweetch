import Cocoa

/// Notices that the previous run died, and turns the system's crash report into something
/// worth opening.
///
/// macOS already writes an `.ips` to ~/Library/Logs/DiagnosticReports/, but it's a JSON blob
/// that gets pruned over time, and nothing tells you it appeared. So on a crash we keep a
/// copy alongside a plain-text summary — exception, signal, and the faulting thread with
/// sweetch's own frames marked, which is the part that says what actually broke.
enum CrashWatch {
    static var dir: URL {
        let d = AppSupport.dir.appendingPathComponent("crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Written while the app runs, removed on a clean exit. Its presence at launch means the
    /// last run ended abruptly — but that also covers `pkill`, so it's only ever treated as a
    /// crash when a matching system report backs it up.
    private static var markerURL: URL { AppSupport.dir.appendingPathComponent(".running") }

    private static let reportsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports")

    /// Call once at launch. If the previous run died, hands back the saved summary — but
    /// possibly a few seconds later: launchd restarts us faster than ReportCrash finishes
    /// writing the .ips, so a report that isn't there yet is worth waiting for. Measured at
    /// less than a second on the first crash this caught, but it's a race either way.
    static func checkPreviousRun(onCrashFound: @escaping (URL) -> Void) {
        defer { markLaunch() }
        guard let markerData = try? Data(contentsOf: markerURL),
              let marker = String(data: markerData, encoding: .utf8),
              let startedAt = TimeInterval(marker.split(separator: "\n").last.map(String.init) ?? "") else {
            return
        }
        let previousStart = Date(timeIntervalSince1970: startedAt)
        waitForReport(after: previousStart, attemptsLeft: 15, onCrashFound: onCrashFound)
    }

    private static func waitForReport(after date: Date, attemptsLeft: Int,
                                      onCrashFound: @escaping (URL) -> Void) {
        if let report = newestSystemReport(after: date), let summary = preserve(report) {
            onCrashFound(summary)
            return
        }
        guard attemptsLeft > 0 else {
            // No report ever showed up: killed (pkill, force quit, a reboot), not crashed.
            log.info("previous run ended without a clean exit, but no crash report appeared — killed, not crashed")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            waitForReport(after: date, attemptsLeft: attemptsLeft - 1, onCrashFound: onCrashFound)
        }
    }

    static func markLaunch() {
        let content = "\(ProcessInfo.processInfo.processIdentifier)\n\(Date().timeIntervalSince1970)"
        try? content.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    /// Only clear the marker if it's still ours — during a handover the incoming instance has
    /// already claimed it, and wiping it would hide a later crash.
    static func markCleanExit() {
        guard let content = try? String(contentsOf: markerURL, encoding: .utf8),
              let pid = Int32(content.split(separator: "\n").first.map(String.init) ?? ""),
              pid == ProcessInfo.processInfo.processIdentifier else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }

    private static func newestSystemReport(after date: Date) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: reportsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("sweetch-") && $0.pathExtension == "ips" }
            .filter { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { $0 > date } ?? false }
            .max { a, b in modified(a) < modified(b) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Copy the report out of the system folder (which prunes) and write the summary next to it.
    private static func preserve(_ report: URL) -> URL? {
        let stamp = ISO8601DateFormatter().string(from: modified(report)).replacingOccurrences(of: ":", with: ".")
        let copy = dir.appendingPathComponent("crash \(stamp).ips")
        let summary = dir.appendingPathComponent("crash \(stamp).txt")
        try? FileManager.default.removeItem(at: copy)
        try? FileManager.default.copyItem(at: report, to: copy)
        let text = summarize(report) ?? "Couldn't parse \(report.lastPathComponent) — see the .ips next to this file."
        try? text.write(to: summary, atomically: true, encoding: .utf8)
        log.error("previous run crashed; report saved to \(summary.path, privacy: .public)")
        return summary
    }

    private static func summarize(_ report: URL) -> String? {
        guard let raw = try? String(contentsOf: report, encoding: .utf8),
              let split = raw.firstIndex(of: "\n") else { return nil }
        // An .ips is two JSON documents: a one-line header, then the body.
        let body = String(raw[raw.index(after: split)...])
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        var lines: [String] = ["sweetch crash report", ""]
        if let time = root["captureTime"] as? String { lines.append("when:        \(time)") }
        if let version = root["appVersion"] as? String { lines.append("version:     \(version)") }
        if let exception = root["exception"] as? [String: Any] {
            lines.append("exception:   \(exception["type"] ?? "?")  signal: \(exception["signal"] ?? "?")")
        }
        if let termination = root["termination"] as? [String: Any] {
            lines.append("termination: \(termination["indicator"] ?? "?")")
        }

        let images = root["usedImages"] as? [[String: Any]] ?? []
        let threads = root["threads"] as? [[String: Any]] ?? []
        if let faulting = threads.first(where: { $0["triggered"] as? Bool == true }) {
            lines.append("")
            lines.append("faulting thread — sweetch's own frames marked with >>:")
            for frame in (faulting["frames"] as? [[String: Any]] ?? []).prefix(30) {
                let index = frame["imageIndex"] as? Int ?? -1
                let image = (index >= 0 && index < images.count) ? (images[index]["name"] as? String ?? "?") : "?"
                let symbol = frame["symbol"] as? String ?? "?"
                let mark = image == "sweetch" ? ">>" : "  "
                lines.append("  \(mark) \(image.padding(toLength: max(image.count, 26), withPad: " ", startingAt: 0))  \(symbol)")
            }
        }
        lines.append("")
        lines.append("The full system report is the .ips file next to this one.")
        return lines.joined(separator: "\n") + "\n"
    }
}
