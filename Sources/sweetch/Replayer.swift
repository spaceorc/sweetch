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

    static func convertLastWord(buffer: KeystrokeBuffer) {
        guard let range = buffer.lastWordRange() else {
            log.info("convert: buffer empty, nothing to convert")
            return
        }
        let snapshot = buffer.snapshot()
        let word = Array(snapshot[range])
        let count = word.count
        let typed = word.map { $0.chars }.joined()
        log.info("convert: replaying \(count, privacy: .public) keystrokes (was: '\(typed, privacy: .public)')")

        // 1. Backspaces, flags=[] to avoid Cmd+Backspace if user still holds the hotkey.
        for _ in 0..<count {
            postKey(keyCode: 51, flags: [], down: true)
            postKey(keyCode: 51, flags: [], down: false)
        }

        // 2. Switch input source.
        InputSourceSwitcher.toggle()

        // 3. Give the receiver a moment to pick up the TIS change.
        usleep(20_000)

        // 4. Replay each keystroke (keyCodes are layout-independent — translation happens
        //    in the receiver against the active TIS).
        for k in word {
            let flags = k.flags.intersection(.maskShift)
            postKey(keyCode: k.keyCode, flags: flags, down: true)
            postKey(keyCode: k.keyCode, flags: flags, down: false)
        }

        // 5. Remember new layout on the same buffer entries so another press toggles back.
        let newSourceID = InputSourceSwitcher.currentSourceID()
        buffer.relabel(range: range, sourceID: newSourceID)
    }

    static func postKeyPair(keyCode: Int64, flags: CGEventFlags) {
        postKey(keyCode: keyCode, flags: flags, down: true)
        postKey(keyCode: keyCode, flags: flags, down: false)
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

    private static func postKey(keyCode: Int64, flags: CGEventFlags, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(keyCode), keyDown: down) else { return }
        event.flags = flags
        // Post at HID level so the event traverses the full input stack like a real key —
        // Chromium-based inputs are stricter about where the event entered from.
        event.post(tap: .cghidEventTap)
    }
}
