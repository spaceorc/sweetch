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
        log.info("convert: replaying \(count, privacy: .public) keystrokes (was: '\(shown(typed), privacy: .public)')")

        // 1. Backspaces, flags=[] to avoid Cmd+Backspace if user still holds the hotkey.
        for _ in 0..<count {
            postKey(keyCode: 51, flags: [], down: true)
            postKey(keyCode: 51, flags: [], down: false)
        }

        // 2. Switch input source — for what's typed next.
        InputSourceSwitcher.toggle()
        usleep(20_000)

        // 3. Replay each keystroke with the character it makes in the other layout carried in
        //    the event. The receiver picks a layout change up when it gets to it — Spotlight
        //    later than 20 ms — and a bare keyCode would come out in the old layout ("ыafari");
        //    the character in the event doesn't wait for it (nor mind a modifier still held).
        let (toSecondary, toPrimary) = LayoutTranslator.buildMaps()
        for k in word {
            let flags = k.flags.intersection(.maskShift)
            let map = InputSourceSwitcher.secondaryIDs.contains(k.sourceID) ? toPrimary : toSecondary
            let text = k.chars.count == 1 ? other(Character(k.chars), in: map) : nil
            postKey(keyCode: k.keyCode, flags: flags, down: true, text: text)
            postKey(keyCode: k.keyCode, flags: flags, down: false, text: text)
        }

        // 4. Remember new layout on the same buffer entries so another press toggles back.
        let newSourceID = InputSourceSwitcher.currentSourceID()
        buffer.relabel(range: range, sourceID: newSourceID)
    }

    /// `c` in the other layout; a capital through its small letter (the maps are built unshifted).
    private static func other(_ c: Character, in map: [Character: Character]) -> String? {
        if let o = map[c] { return String(o) }
        let lower = Character(c.lowercased())
        guard lower != c, let o = map[lower] else { return nil }
        return o.uppercased()
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
