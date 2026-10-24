import AppKit

/// What the user does in sweetch's window — each click, where, on what, and each page opened — a
/// line per event in `ui/<day>-<host>.jsonl`, synced between the Macs: for finding later what was
/// clicked and did nothing, what's looked for and not found, what's never used. No text the user
/// wrote or said: of what's under the click only its role, and its label when it's a control's
/// (a button's title, a tab's name). Nothing while incognito.
enum UILog {
    private static let lock = NSLock()
    private static let host = (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac").lowercased()

    static var dir: URL { AppSupport.dir.appendingPathComponent("ui", isDirectory: true) }

    static func record(_ event: String, _ fields: [String: Any] = [:]) {
        guard !Privacy.incognito else { return }
        var record = fields
        record["e"] = event
        record["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("\(f.string(from: Date()))-\(host).jsonl")
        lock.withLock {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let line = data + Data("\n".utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    /// Roles whose label is the app's own words, not the user's (a list's rows hold dictations).
    private static let controls: Set<NSAccessibility.Role> = [.button, .link, .radioButton, .checkBox, .popUpButton,
                                                              .menuButton, .tabGroup, .disclosureTriangle]

    /// A click in `window`: where (a fraction of its content, and its size), on what, on which page.
    static func click(_ event: NSEvent, in window: NSWindow, page: String) {
        guard let content = window.contentView else { return }
        let point = content.convert(event.locationInWindow, from: nil)
        var fields: [String: Any] = [
            "page": page,
            "x": (point.x / max(1, content.bounds.width) * 1000).rounded() / 1000,
            "y": ((content.bounds.height - point.y) / max(1, content.bounds.height) * 1000).rounded() / 1000,
            "w": Int(content.bounds.width), "h": Int(content.bounds.height),
            "clicks": event.clickCount,
        ]
        let screen = window.convertPoint(toScreen: event.locationInWindow)
        if let element = content.accessibilityHitTest(screen) as? NSAccessibilityProtocol {
            let role = element.accessibilityRole()
            fields["role"] = role?.rawValue ?? "?"
            if let role, controls.contains(role),
               let label = element.accessibilityLabel() ?? element.accessibilityTitle(), !label.isEmpty {
                fields["label"] = String(label.prefix(60))
            }
        }
        record("click", fields)
    }
}
