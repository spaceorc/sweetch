import Cocoa
import ApplicationServices

/// Hold Space in a text field to dictate — the gesture Claude Code uses in a terminal, everywhere.
///
/// Whose dictation it is depends on where the user is:
/// - **Claude desktop** toggles its own with ⌘D: holding Space erases the one space it typed and
///   presses ⌘D, releasing presses ⌘D again.
/// - **Claude Code in iTerm2** has its own hold-Space push-to-talk, so Space is left alone there.
/// - **Any other text field**, a plain iTerm2 shell included, gets sweetch's own (`Dictation`).
///
/// A tap is left alone — it types its space as always. "Held" means the first autorepeat, or
/// `holdDelay` without one (for people with key repeat off), whichever comes first; either
/// way exactly one space has reached the app by then, so one Backspace undoes it. Escape during
/// our own dictation throws the recording away.
///
/// Runs on the event-tap thread (the main run loop).
final class HoldToTalk {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    private static let dictationKeyCode: Int64 = 2   // D, with ⌘ — Claude's dictation toggle
    private static let holdDelay: TimeInterval = 0.35
    private static let spaceKeyCode: Int64 = 49
    private static let escapeKeyCode: Int64 = 53

    private enum State {
        case idle
        case pending(Timer)                     // Space is down and its space typed; not held yet
        case claudeRecording                    // Claude desktop's dictation, toggled with ⌘D
        case dictating                          // ours
        case swallowing                         // ours, cancelled; eat Space until it's released
        case awaitingTerminal                   // held in iTerm before it said whether Claude Code is there
        case passthrough                        // held, but not ours to take — let it be
    }
    private var state: State = .idle
    /// Spaces this press has typed into the app so far: one, plus repeats let through while
    /// waiting on iTerm. Taking the hold over erases them all.
    private var spacesTyped = 0
    /// Whether Claude Code runs in the focused iTerm pane, as asked at this press; nil until known.
    private var claudeInPane: Bool?
    /// A hold handed to an app's own dictation, recorded when Space comes up.
    private var handoff: (app: NSRunningApplication, to: String, at: Date)?
    /// We're hearing that hold too, silently, to compare with what the app writes.
    private var shadowing = false
    private let dictation: Dictation
    private let isDictationEnabled: () -> Bool
    /// Space was taken over: the keystroke buffer no longer matches the document.
    private let onTakeOver: () -> Void

    init(dictation: Dictation, isDictationEnabled: @escaping () -> Bool, onTakeOver: @escaping () -> Void) {
        self.dictation = dictation
        self.isDictationEnabled = isDictationEnabled
        self.onTakeOver = onTakeOver
    }

    /// Sees every real key event first; returns true to swallow it.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.spaceKeyCode else {
            switch (type, state) {
            // Typing on while Space is still down (fast "a b") — that was never a hold.
            case (.keyDown, .pending(let timer)):
                timer.invalidate()
                state = .idle
            case (.keyDown, .dictating) where keyCode == Self.escapeKeyCode:
                dictation.cancel()
                state = .swallowing
                return true
            default:
                break
            }
            return false
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch (type, state) {
        case (.keyDown, .idle) where !isRepeat:
            guard event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty else { return false }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            guard front != Bundle.main.bundleIdentifier,
                  front == Self.claudeBundleID || isDictationEnabled() else { return false }
            handoff = nil
            spacesTyped = 1
            claudeInPane = nil
            if front == TerminalProbe.iTermBundleID {
                TerminalProbe.ask { [weak self] found in self?.terminalAnswered(found) }
            }
            let timer = Timer(timeInterval: Self.holdDelay, repeats: false) { [weak self] _ in self?.becomeHeld() }
            RunLoop.main.add(timer, forMode: .common)
            state = .pending(timer)
            return false

        case (.keyDown, .pending(let timer)) where isRepeat:
            timer.invalidate()
            becomeHeld()
            return isTakenOver

        case (.keyDown, .claudeRecording), (.keyDown, .dictating), (.keyDown, .swallowing):
            return true

        case (.keyDown, .awaitingTerminal):
            spacesTyped += 1
            return false

        case (.keyUp, .pending(let timer)):
            timer.invalidate()
            state = .idle
            return false

        // Space's release always goes through. Swallowed, the system takes Space as still down, and
        // the next real press anywhere arrives as an autorepeat — which Claude Code in a terminal
        // doesn't take for the start of a hold. A release on its own types nothing.
        case (.keyUp, .claudeRecording):
            Replayer.postKeyPair(keyCode: Self.dictationKeyCode, flags: .maskCommand)
            log.info("hold-to-talk: Claude dictation off")
            state = .idle
            recordHandoff()
            return false

        case (.keyUp, .dictating):
            dictation.finish()
            state = .idle
            return false

        case (.keyUp, .swallowing):
            state = .idle
            return false

        case (.keyUp, .passthrough), (.keyUp, .awaitingTerminal):
            state = .idle
            recordHandoff()
            return false

        default:
            return false
        }
    }

    private var isTakenOver: Bool {
        switch state {
        case .claudeRecording, .dictating, .swallowing: return true
        default: return false
        }
    }

    private func becomeHeld() {
        guard case .pending = state else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { state = .passthrough; return }

        switch app.bundleIdentifier {
        case Self.claudeBundleID:
            guard focusIsTextInput() else { return passThrough("Space held outside Claude's prompt") }
            eraseTypedSpace()
            Replayer.postKeyPair(keyCode: Self.dictationKeyCode, flags: .maskCommand)
            log.info("hold-to-talk: Claude dictation on")
            state = .claudeRecording
            handOff(app, to: "Claude desktop")

        case TerminalProbe.iTermBundleID:
            guard let claudeInPane else {
                log.info("hold-to-talk: held in iTerm before it said what runs there — waiting")
                state = .awaitingTerminal
                return
            }
            decideTerminal(claudeInPane: claudeInPane, app: app)

        default:
            guard focusIsTextInput() else { return passThrough("Space held outside a text field") }
            startDictation(in: app)
        }
    }

    private func terminalAnswered(_ found: Bool) {
        claudeInPane = found
        guard case .awaitingTerminal = state,
              let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == TerminalProbe.iTermBundleID else { return }
        decideTerminal(claudeInPane: found, app: app)
    }

    private func decideTerminal(claudeInPane: Bool, app: NSRunningApplication) {
        if claudeInPane {
            passThrough("Claude Code has the focused iTerm pane — its own push-to-talk")
            handOff(app, to: "Claude Code")
        } else {
            // A terminal view isn't a text field to Accessibility, but it takes text all the same.
            startDictation(in: app)
        }
    }

    /// In a terminal the typed spaces are erased (Shift-← would reach the shell as a key). Anywhere
    /// else they are selected instead, and what's dictated is typed over them: a Backspace on a
    /// blank line in a JetBrains editor takes the whole line with it.
    private func startDictation(in app: NSRunningApplication) {
        let typed = spacesTyped
        let inTerminal = app.bundleIdentifier == TerminalProbe.iTermBundleID
        if inTerminal {
            eraseTypedSpace()
        } else {
            for _ in 0..<typed { Replayer.postKeyPair(keyCode: 123, flags: .maskShift) }   // Shift-←
            spacesTyped = 0
            onTakeOver()
        }
        guard dictation.begin(app: app, spaceSelected: !inTerminal) else {
            if inTerminal {
                for _ in 0..<typed { Replayer.postKeyPair(keyCode: Self.spaceKeyCode, flags: []) }
            } else {
                Replayer.postKeyPair(keyCode: 124, flags: [])   // → drops the selection, after the spaces
            }
            return passThrough("dictation unavailable")
        }
        state = .dictating
    }

    private func eraseTypedSpace() {
        for _ in 0..<spacesTyped { Replayer.postKeyPair(keyCode: 51, flags: []) }   // what the press typed
        spacesTyped = 0
        onTakeOver()
    }

    private func handOff(_ app: NSRunningApplication, to target: String) {
        handoff = (app, target, Date())
        shadowing = isDictationEnabled() && dictation.beginShadow(app: app, target: target)
    }

    private func recordHandoff() {
        guard let handoff else { return }
        self.handoff = nil
        if shadowing {
            shadowing = false
            dictation.finishShadow()   // records the handoff along with what both heard
            return
        }
        DictationStore.recordHandoff(app: handoff.app, to: handoff.to, startedAt: handoff.at,
                                     seconds: Date().timeIntervalSince(handoff.at))
    }

    private func passThrough(_ why: String) {
        log.info("hold-to-talk: \(why, privacy: .public) — passing through")
        state = .passthrough
    }

    /// Only hijack Space while typing in a text field — elsewhere a Backspace could navigate.
    private func focusIsTextInput() -> Bool {
        guard let el = SelectionConverter.focusedElement(wait: false) else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        return ["AXTextArea", "AXTextField", "AXComboBox"].contains(role as? String ?? "")
    }
}
