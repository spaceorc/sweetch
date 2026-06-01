import Cocoa
import ApplicationServices

enum SelectionConverter {
    enum Result {
        case converted
        case noSelection
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
    static func tryConvert() -> Result {
        guard let element = focusedElement() else {
            log.info("convert-selection: no focused element")
            return .noSelection
        }
        guard let selectedText = readAXSelectedText(element), !selectedText.isEmpty else {
            log.info("convert-selection: empty AX selection — falling back to last-word")
            return .noSelection
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

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func readAXSelectedText(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}
