import Cocoa
import Carbon

enum Replayer {
    /// ASCII "sweetch\0" — set on our synthetic event source so the tap can recognise its own events.
    static let syntheticEventMarker: Int64 = 0x73776565_74636800

    // Use combinedSessionState (not privateState) so events look like normal session events
    // to apps that inspect eventSourceStateID — Chromium-based apps (Slack, Discord, VS Code)
    // sometimes ignore events from privateState as "not trusted".
    private static let eventSource: CGEventSource? = {
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.userData = syntheticEventMarker
        return src
    }()

    /// The keystrokes in `range` — words and the spaces between and after them — typed again in the
    /// other layout than the one they were typed in, which stays on for what comes next (⌥Space,
    /// and AutoLayout on its own). Each key carries the character it makes there, from the layout
    /// itself — not the event's, which can be the previous layout's (TypingLog) — so the receiver
    /// needn't have caught up with the switch («ыafari» in Spotlight). Returns the layout now on.
    @discardableResult
    static func convert(range: Range<Int>, buffer: KeystrokeBuffer) -> String? {
        let snapshot = buffer.snapshot()
        guard range.lowerBound >= 0, range.upperBound <= snapshot.count, !range.isEmpty else { return nil }
        let keys = Array(snapshot[range])
        let wasSecondary = InputSourceSwitcher.secondaryIDs.contains(keys[0].sourceID)
        let targetIDs = wasSecondary ? InputSourceSwitcher.primaryIDs : InputSourceSwitcher.secondaryIDs
        let chars = LayoutTranslator.keyChars()
        let target = wasSecondary ? chars.primary : chars.secondary
        // Backspaces with no modifiers: the hotkey's may still be held.
        for _ in keys { postKeyPair(keyCode: 51, flags: []) }
        InputSourceSwitcher.select(targetIDs)
        usleep(20_000)
        for k in keys {
            let shift = k.flags.contains(.maskShift)
            let text = k.keyCode == 49 ? nil : target[Int(k.keyCode) | (shift ? 0x100 : 0)].map(String.init)
            let flags = k.flags.intersection(.maskShift)
            postKey(keyCode: k.keyCode, flags: flags, down: true, text: text)
            postKey(keyCode: k.keyCode, flags: flags, down: false, text: text)
        }
        let now = InputSourceSwitcher.currentSourceID()
        buffer.relabel(range: range, sourceID: now)
        return now
    }

    static func postKeyPair(keyCode: Int64, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: true)
        postKey(keyCode: keyCode, flags: flags, down: false)
    }

    /// Delete `count` characters, then type `text` literally. Used to replace a span
    /// of already-typed text with an arbitrary Unicode string (LLM correction).
    static func replace(deleteCount: Int, with text: String) {
        for _ in 0..<deleteCount {
            postKeyPair(keyCode: 51, flags: [])   // Backspace
        }
        usleep(20_000)
        // Char-by-char (not one big string) — Chromium/Electron inputs are happier
        // with discrete keystrokes; matches what selection-convert already does.
        for ch in text {
            postUnicodeString(String(ch))
            usleep(1_000)
        }
    }

    /// Wait (briefly) for the user's hotkey modifiers to lift before we synthesize keys.
    /// CGEventSource.flagsState is live only off the event-tap thread — call from a
    /// background queue / Task, never from the tap callback.
    static func waitForModifierRelease(timeout: TimeInterval = 0.5) {
        let interesting: CGEventFlags = [.maskAlternate, .maskCommand, .maskControl, .maskShift]
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if CGEventSource.flagsState(.combinedSessionState).intersection(interesting).isEmpty {
                return
            }
            usleep(5_000)
        }
    }

    /// Send a literal Unicode string as a synthesized keystroke. Used for chars that
    /// don't map to any key in the target layout (emojis, etc).
    static func postUnicodeString(_ s: String) {
        let utf16 = Array(s.utf16)
        if let down = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: true) {
            utf16.withUnsafeBufferPointer { buf in
                down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: eventSource, virtualKey: 0, keyDown: false) {
            utf16.withUnsafeBufferPointer { buf in
                up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            }
            up.post(tap: .cghidEventTap)
        }
    }

    private static func postKey(keyCode: Int64, flags: CGEventFlags, down: Bool, text: String? = nil) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = flags
        if let text {
            let utf16 = Array(text.utf16)
            utf16.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
        }
        // Post at HID level so the event traverses the full input stack like a real key —
        // Chromium-based inputs are stricter about where the event entered from.
        event.post(tap: .cghidEventTap)
    }
}
