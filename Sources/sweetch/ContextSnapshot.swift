import Cocoa
import ApplicationServices

/// What was in front of the user as they started speaking: the app, the window, the field and the
/// text around the cursor, every text the window shows through Accessibility, and a picture of the
/// window for when Accessibility shows nothing.
///
/// Phase 0 of dictation only records it beside the recording. The point is to measure, offline,
/// which of these makes recognition better before any of it is used.
enum ContextSnapshot {
    /// The insertion point of the focused text field: what it holds and where the cursor is.
    struct Field {
        let element: AXUIElement
        let role: String?
        let value: String?
        let selection: NSRange?

        var textBeforeCursor: String? {
            guard let value, let selection else { return nil }
            let ns = value as NSString
            return ns.substring(to: min(selection.location, ns.length))
        }

        static func focused() -> Field? {
            guard let element = SelectionConverter.focusedElement(wait: false) else { return nil }
            return read(element)
        }

        static func read(_ element: AXUIElement) -> Field {
            AXUIElementSetMessagingTimeout(element, 0.3)
            return Field(element: element,
                         role: AX.string(element, kAXRoleAttribute),
                         value: AX.string(element, kAXValueAttribute),
                         selection: AX.range(element, kAXSelectedTextRangeAttribute))
        }

        /// The field's text, cut down to a window around the cursor when it's huge (a terminal's
        /// whole scrollback).
        func excerpt(limit: Int = 20_000) -> String? {
            guard let value else { return nil }
            let ns = value as NSString
            guard ns.length > limit else { return value }
            let cursor = min(selection?.location ?? ns.length, ns.length)
            let start = max(0, min(cursor - limit * 3 / 4, ns.length - limit))
            return ns.substring(with: NSRange(location: start, length: limit))
        }
    }

    /// Gathers everything and writes `context.json` (and `window.png`) into `dir`. Slow — seconds
    /// on a big window — so it runs off the main thread, while the user speaks.
    static func capture(app: NSRunningApplication, field: Field?, into dir: URL) {
        let started = Date()
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.3)
        let window = AX.element(appElement, kAXFocusedWindowAttribute)

        var context: [String: Any] = [
            "app": app.localizedName ?? "",
            "bundle_id": app.bundleIdentifier ?? "",
        ]
        if let window, let title = AX.string(window, kAXTitleAttribute) { context["window_title"] = title }
        if let field {
            var f: [String: Any] = [:]
            f["role"] = field.role
            f["value"] = field.excerpt()
            f["value_length"] = field.value.map { ($0 as NSString).length }
            if let s = field.selection { f["selection"] = ["location": s.location, "length": s.length] }
            context["field"] = f
        }
        if let window { context["window_texts"] = windowTexts(window) }
        context["ax_seconds"] = Date().timeIntervalSince(started)

        if let id = windowID(of: app) {
            let png = dir.appendingPathComponent("window.png")
            do {
                try Subprocess.run("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), png.path])
                context["screenshot"] = png.lastPathComponent
            } catch {
                log.error("dictation: window screenshot failed: \(String(describing: error), privacy: .public)")
            }
        }
        context["seconds"] = Date().timeIntervalSince(started)
        DictationStore.write(context, to: dir.appendingPathComponent("context.json"))
    }

    private static let textRoles: Set<String> = ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink", "AXCell"]

    /// Every distinct text the window shows, in tree order (roughly reading order). Bounded in
    /// nodes, characters and time: a chat window can hold years of history.
    private static func windowTexts(_ window: AXUIElement) -> [String] {
        let deadline = Date().addingTimeInterval(1.5)
        var texts: [String] = []
        var seen = Set<String>()
        var chars = 0
        var visited = 0
        var stack: [(AXUIElement, Int)] = [(window, 0)]
        while let (element, depth) = stack.popLast() {
            visited += 1
            if visited > 4000 || chars > 40_000 || Date() > deadline { break }
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            var candidates: [String?] = [AX.string(element, kAXTitleAttribute), AX.string(element, kAXDescriptionAttribute)]
            if textRoles.contains(role) { candidates.append(AX.string(element, kAXValueAttribute)) }
            for case let text? in candidates {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.count >= 2, seen.insert(trimmed).inserted else { continue }
                texts.append(String(trimmed.prefix(4000)))
                chars += min(trimmed.count, 4000)
            }
            guard depth < 40 else { continue }
            // Children pushed in reverse so they pop in order.
            for child in AX.children(element).reversed() { stack.append((child, depth + 1)) }
        }
        return texts
    }

    /// The app's frontmost on-screen window, as the window server numbers it.
    private static func windowID(of app: NSRunningApplication) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        return list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0
        }?[kCGWindowNumber as String] as? CGWindowID
    }
}

/// Typed reads of Accessibility attributes.
enum AX {
    /// The system-wide focused element, as is — no waking an Electron app's tree.
    static func focusedElement() -> AXUIElement? {
        element(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    static func range(_ element: AXUIElement, _ attribute: String) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
}
