import Cocoa
import ApplicationServices

enum SelectionConverter {
    enum Result {
        case converted
        case noSelection
        /// A selection exists but the user was just typing (keystroke buffer non-empty),
        /// so it's almost certainly an inline-autocomplete artifact (e.g. Chrome omnibox
        /// highlights its suggested completion). We dismissed it with one Backspace;
        /// the caller should proceed with last-word conversion.
        case autocompleteDismissed
    }

    /// Read selection via AX, write replacement by typing keys.
    ///
    /// We deliberately *don't* use `AXUIElementSetAttributeValue` for the write —
    /// Electron-based apps (Slack, Discord, VS Code) return `.success` from AX-set
    /// but silently fail to update the underlying contenteditable. Typing via
    /// synthesised key events is the only thing that works everywhere.
    ///
    /// Must be called off the event-tap thread (the background dispatch in
    /// handleConvert): we wait for the user's hotkey modifiers to release using
    /// CGEventSource.flagsState, which is only live when the tap callback has returned.
    static func tryConvert(typedText: String) -> Result {
        guard let element = focusedElement() else {
            log.info("convert-selection: no focused element")
            return .noSelection
        }
        guard let selectedText = readAXSelectedText(element), !selectedText.isEmpty else {
            log.info("convert-selection: empty AX selection — falling back to last-word")
            return .noSelection
        }

        // Distinguish a real selection from an inline-autocomplete highlight (Chrome's
        // omnibox selects its suggested completion). The autocomplete tail is text the
        // user did NOT type, so: if the keystroke buffer has content and the selection
        // is not a substring of it, it's an autocomplete artifact — dismiss and let the
        // caller convert the last typed word instead. A selection that matches what was
        // just typed (e.g. made via Shift+Home) is real and gets converted as such.
        if !typedText.isEmpty && !typedText.contains(selectedText) {
            log.info("convert-selection: selection '\(selectedText, privacy: .public)' not part of typed text — autocomplete artifact, dismissing")
            waitForModifierRelease()
            Replayer.postKeyPair(keyCode: 51, flags: [])  // Backspace removes the highlighted completion
            usleep(30_000)
            return .autocompleteDismissed
        }

        let (converted, targetIDs) = translate(selectedText)
        log.info("convert-selection: '\(selectedText, privacy: .public)' -> '\(converted, privacy: .public)'")

        waitForModifierRelease()

        // Backspace once — that deletes the entire highlighted selection in every text widget.
        Replayer.postKeyPair(keyCode: 51, flags: [])
        usleep(20_000)

        InputSourceSwitcher.select(byIDs: targetIDs)
        usleep(20_000)

        typeText(converted, layoutIDs: targetIDs)
        return .converted
    }

    /// The current real selection text, or nil if there's no selection or it's an
    /// inline-autocomplete artifact (same heuristic as tryConvert). Read-only — used by
    /// the LLM corrector to decide between "correct the selection" and "correct the buffer".
    static func currentSelection(typedText: String) -> String? {
        guard let element = focusedElement(wait: false),
              let sel = readAXSelectedText(element), !sel.isEmpty else { return nil }
        if !typedText.isEmpty && !typedText.contains(sel) { return nil }  // autocomplete artifact
        return sel
    }

    private static func typeText(_ text: String, layoutIDs: [String]) {
        let reverseMap = LayoutTranslator.reverseKeyMap(forIDs: layoutIDs)
        for c in text {
            if let kcAndShift = reverseMap[c] {
                let flags: CGEventFlags = kcAndShift.shift ? .maskShift : []
                Replayer.postKeyPair(keyCode: Int64(kcAndShift.keyCode), flags: flags)
            } else {
                // Char isn't on the target layout's keyboard — insert as literal Unicode.
                Replayer.postUnicodeString(String(c))
            }
            usleep(1_000)
        }
    }

    private static func translate(_ text: String) -> (converted: String, targetIDs: [String]) {
        let (p2s, s2p) = LayoutTranslator.buildMaps()
        let script = LayoutTranslator.dominantScript(text)
        let map: [Character: Character]
        let targetIDs: [String]
        switch script {
        case .latin:
            map = p2s
            targetIDs = InputSourceSwitcher.secondaryIDs
        case .cyrillic:
            map = s2p
            targetIDs = InputSourceSwitcher.primaryIDs
        case .other:
            let currentInPrimary = InputSourceSwitcher.primaryIDs.contains(InputSourceSwitcher.currentSourceID())
            map = currentInPrimary ? p2s : s2p
            targetIDs = currentInPrimary ? InputSourceSwitcher.secondaryIDs : InputSourceSwitcher.primaryIDs
        }
        return (String(text.map { map[$0] ?? $0 }), targetIDs)
    }

    private static func waitForModifierRelease(timeout: TimeInterval = 0.5) {
        let interesting: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interesting).isEmpty {
                return
            }
            usleep(5_000)
        }
        log.info("convert-selection: modifier-release wait timed out (\(timeout, privacy: .public)s)")
    }

    /// The system-wide focused element. If there is none, the frontmost app may be an Electron
    /// one whose Accessibility tree isn't built yet — one asked too early (right at launch) never
    /// builds it — so ask again and, if `wait`, give it a moment before giving up. Callers on the
    /// event-tap thread pass `wait: false`: blocking there stalls typing.
    static func focusedElement(wait: Bool = true) -> AXUIElement? {
        if let el = copyFocusedElement() { return el }
        guard let app = MainQueue.sync({ NSWorkspace.shared.frontmostApplication }),
              wakeAccessibility(of: app), wait else { return nil }
        for _ in 0..<10 {
            usleep(50_000)
            if let el = copyFocusedElement() {
                log.info("convert-selection: focused element appeared after waking AX")
                return el
            }
        }
        return nil
    }

    private static func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    /// Electron apps (Claude, sometimes Slack) build no Accessibility tree until an assistive
    /// client asks for one: the system-wide focused element comes back empty, so a perfectly
    /// real selection is invisible to convert. Setting `AXManualAccessibility` is that ask.
    /// Non-Electron apps reject it harmlessly. Returns whether the app accepted it.
    @discardableResult
    static func wakeAccessibility(of app: NSRunningApplication) -> Bool {
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let ok = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success
        if ok { log.info("AXManualAccessibility enabled for \(app.bundleIdentifier ?? "?", privacy: .public)") }
        return ok
    }

    private static func readAXSelectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}
