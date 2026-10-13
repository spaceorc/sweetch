import Foundation

/// Whether the focused iTerm2 pane is running Claude Code, which has a hold-Space push-to-talk of
/// its own — there, holding Space must stay Claude Code's.
///
/// iTerm names the focused pane's tty over AppleScript; `ps` then says which process group owns
/// that tty's foreground. The AppleScript round trip takes ~0.1 s, far too long for the event-tap
/// thread, so it is asked as Space goes down in iTerm and handed back on the main thread — usually
/// before a hold is decided a key-repeat delay later. The first ask can wait on the Automation
/// prompt for as long as the user takes to answer it.
enum TerminalProbe {
    static let iTermBundleID = "com.googlecode.iterm2"

    private static let queue = DispatchQueue(label: "sweetch.terminal-probe")
    /// A pane rarely changes between two presses of Space this close together, and typing a
    /// sentence shouldn't run AppleScript at every word.
    private static let freshFor: TimeInterval = 2
    // Main-thread state: callers waiting on the probe in flight, and the last answer.
    private static var waiting: [(Bool) -> Void] = []
    private static var last: (found: Bool, at: Date)?

    /// Main thread only; `answer` is called on it — at once when the last answer is fresh. Asks
    /// joining a probe already in flight share its answer.
    static func ask(_ answer: @escaping (Bool) -> Void) {
        if let last, Date().timeIntervalSince(last.at) < freshFor { return answer(last.found) }
        waiting.append(answer)
        guard waiting.count == 1 else { return }
        queue.async {
            let found = Self.probe()
            DispatchQueue.main.async {
                log.info("terminal probe: Claude Code in the focused iTerm pane = \(found, privacy: .public)")
                Self.last = (found, Date())
                let answers = Self.waiting
                Self.waiting = []
                answers.forEach { $0(found) }
            }
        }
    }

    private static func probe() -> Bool {
        let script = "tell application \"iTerm2\" to tty of current session of current window"
        guard let tty = Subprocess.output("/usr/bin/osascript", ["-e", script])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              tty.hasPrefix("/dev/") else { return false }
        guard let ps = Subprocess.output("/bin/ps", ["-t", String(tty.dropFirst(5)), "-o", "tpgid=,pgid=,comm="]) else {
            return false
        }
        // The foreground group is the one whose pgid is the terminal's tpgid.
        for line in ps.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2)
            guard fields.count == 3, fields[0] == fields[1] else { continue }
            if fields[2].split(separator: "/").last == "claude" { return true }
        }
        return false
    }
}

/// Runs a command-line tool to completion.
enum Subprocess {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The tool's stdout, or nil if it could not run or exited non-zero.
    static func output(_ path: String, _ arguments: [String]) -> String? {
        try? run(path, arguments)
    }

    /// Blocks until the tool exits or `timeout` passes. Throws with the tail of its stderr on a
    /// non-zero exit. Call off the main thread.
    @discardableResult
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 30) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice
        try task.run()

        // Drain both pipes while the tool runs — a full pipe would block it forever.
        var out = Data()
        var err = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { out = stdout.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global().async { err = stderr.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { usleep(10_000) }
        if task.isRunning {
            task.terminate()
            throw Failure(description: "\((path as NSString).lastPathComponent) did not finish within \(Int(timeout))s")
        }
        group.wait()
        guard task.terminationStatus == 0 else {
            let tail = String(String(decoding: err, as: UTF8.self).suffix(500)).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(description: "\((path as NSString).lastPathComponent) exited with \(task.terminationStatus): \(tail)")
        }
        return String(decoding: out, as: UTF8.self)
    }
}
