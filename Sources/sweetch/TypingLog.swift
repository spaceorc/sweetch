import Cocoa

/// Every key pressed on this Mac, for learning how the user types — their slips, their speed, what
/// they put right and how — as the iPhone keyboard's log does for the phone: each key's press and
/// release (to the millisecond; a release carries how many times the key repeated while held), its
/// key code and character, the modifiers, the layout; the app in
/// front when it changes; clicks (the cursor moved); our own convert and correction hotkeys.
/// typing/<day>-<host>.jsonl, synced with the Mac mini like the phone's.
///
/// Nothing while private (Privacy.swift): incognito, a private browser window, a password field or
/// app — only a mark that something was left out. Private is known within a second of it starting,
/// so lines wait two seconds before they're written, and those from just before it was noticed are
/// dropped unwritten.
final class TypingLog {
    static let shared = TypingLog()

    private static let delay: TimeInterval = 2
    private let queue = DispatchQueue(label: "sweetch.typinglog", qos: .utility)
    private var pending: [(t: TimeInterval, line: String)] = []
    private var lastApp: String?
    private var privateSince: TimeInterval?
    private let host = (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac").lowercased()
    private var timer: DispatchSourceTimer?
    /// Autorepeats of a key held, counted rather than logged one by one: Space held to dictate
    /// repeats ~30 times a second, and made 80% of the log (20 Oct). Its release carries the count.
    private var repeats: [Int64: Int] = [:]

    private init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flush(force: false) }
        timer.resume()
        self.timer = timer
    }

    static var dir: URL { AppSupport.dir.appendingPathComponent("typing", isDirectory: true) }

    /// Whether what's in front is private now — from the privacy watch (AppDelegate), on every app
    /// switch and once a second. Going private drops what was taken in the second before.
    func setPrivate(_ on: Bool) {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            if on, privateSince == nil {
                privateSince = now
                pending.removeAll { $0.t > now - 1.2 }
                append(now, ["e": "private"])
            } else if !on, privateSince != nil {
                privateSince = nil
                append(now, ["e": "private-end"])
            }
        }
    }

    /// A real key event — down, up, or a modifier — off the event tap.
    func key(_ type: CGEventType, _ event: CGEvent) {
        let now = Date().timeIntervalSince1970
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        var fields: [String: Any] = ["k": code]
        switch type {
        case .keyDown:
            fields["e"] = "d"
            var length = 0
            var chars: [UniChar] = [0, 0, 0, 0]
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            if length > 0 { fields["c"] = String(utf16CodeUnits: chars, count: length) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                queue.async { [self] in repeats[code, default: 0] += 1 }
                return
            }
            fields["l"] = Self.layout()
        case .keyUp:
            fields["e"] = "u"
        case .flagsChanged: fields["e"] = "f"
        default: return
        }
        var mods = ""
        if flags.contains(.maskShift) { mods += "⇧" }
        if flags.contains(.maskControl) { mods += "⌃" }
        if flags.contains(.maskAlternate) { mods += "⌥" }
        if flags.contains(.maskCommand) { mods += "⌘" }
        if flags.contains(.maskAlphaShift) { mods += "⇪" }
        if !mods.isEmpty { fields["m"] = mods }
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        queue.async { [self] in
            if type == .keyUp, let n = repeats.removeValue(forKey: code) { fields["r"] = n }
            guard privateSince == nil else { return }
            if app != lastApp {
                lastApp = app
                append(now, ["e": "app", "id": app])
            }
            append(now, fields)
        }
    }

    /// Something else worth knowing beside the keys: a click, our hotkeys.
    func note(_ name: String, _ fields: [String: Any] = [:]) {
        let now = Date().timeIntervalSince1970
        queue.async { [self] in
            guard privateSince == nil else { return }
            var all = fields
            all["e"] = name
            append(now, all)
        }
    }

    /// Everything still waiting, written now (on quit).
    func flushNow() { queue.sync { flush(force: true) } }

    private func append(_ t: TimeInterval, _ fields: [String: Any]) {
        var all = fields
        all["t"] = (t * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys, .withoutEscapingSlashes]),
              let line = String(data: data, encoding: .utf8) else { return }
        pending.append((t, line))
    }

    private func flush(force: Bool) {
        let cut = Date().timeIntervalSince1970 - (force ? 0 : Self.delay)
        let ready = pending.prefix { $0.t <= cut }
        guard !ready.isEmpty else { return }
        pending.removeFirst(ready.count)
        // A day's file each, by the day the line was taken.
        var byDay: [String: [String]] = [:]
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        for item in ready { byDay[f.string(from: Date(timeIntervalSince1970: item.t)), default: []].append(item.line) }
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        for (day, lines) in byDay {
            let url = Self.dir.appendingPathComponent("\(day)-\(host).jsonl")
            let data = Data((lines.joined(separator: "\n") + "\n").utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// The layout in use, short: "en", "ru", or its id.
    private static func layout() -> String {
        let id = InputSourceSwitcher.currentSourceID()
        if InputSourceSwitcher.primaryIDs.contains(id) { return "en" }
        if InputSourceSwitcher.secondaryIDs.contains(id) { return "ru" }
        return id
    }
}
