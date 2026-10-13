import Cocoa
import ApplicationServices

/// sweetch's own dictation, for apps without one: hold Space in a text field, speak, release.
///
/// Phase 0 of the experiment (see the README): recognition is a single plain listening in Russian
/// with no prefix — the baseline. Every dictation leaves a folder in `DictationStore.dir` with the
/// recording, what was in front of the user (`context.json`, `window.png`), what whisper heard and
/// what was typed (`session.json`), and what the user turned it into (`followup.json`). That is the
/// dataset the next phase measures prefix strategies against.
///
/// `begin`, `finish` and `cancel` are called on the main thread (the event tap's).
final class Dictation {
    private let overlay: LoaderOverlay
    private let followUp = DictationFollowUp()
    private let queue = DispatchQueue(label: "sweetch.dictation")
    private var recorder: AudioRecorder?
    private var current: Session?

    private struct Session {
        let dir: URL
        let app: NSRunningApplication
        let startedAt: Date
    }

    init(overlay: LoaderOverlay) {
        self.overlay = overlay
    }

    /// False when the hold can't be recorded — the caller then lets Space be Space.
    func begin(app: NSRunningApplication) -> Bool {
        if let missing = Whisper.missing() {
            log.error("dictation: unavailable — missing \(missing, privacy: .public)")
            return false
        }
        switch AudioRecorder.checkPermission() {
        case .granted: break
        case .asked:
            log.info("dictation: asked for microphone access; try again once it's granted")
            return false
        case .denied:
            log.error("dictation: microphone access denied — System Settings › Privacy & Security › Microphone")
            return false
        }
        followUp.finish(reason: "next dictation")

        let dir = DictationStore.newSessionDir()
        let session = Session(dir: dir, app: app, startedAt: Date())
        current = session
        let recorder = AudioRecorder()
        self.recorder = recorder
        overlay.show(caption: "listening…", spinning: false, symbol: "mic.fill")
        log.info("dictation: listening in \(app.bundleIdentifier ?? "?", privacy: .public) → \(dir.lastPathComponent, privacy: .public)")

        queue.async {
            do {
                try recorder.start(to: dir.appendingPathComponent("recording.caf"))
            } catch {
                log.error("dictation: recording failed to start: \(String(describing: error), privacy: .public)")
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // After the Backspace that took back the held space has landed.
            usleep(100_000)
            ContextSnapshot.capture(app: app, field: ContextSnapshot.Field.focused(), into: dir)
        }
        return true
    }

    /// A plain Return is about to reach the app (event-tap thread).
    func noteReturn() {
        followUp.noteReturn()
    }

    func cancel() {
        guard let session = current, let recorder else { return }
        current = nil
        self.recorder = nil
        overlay.hide()
        queue.async {
            recorder.stop()
            DictationStore.write(["cancelled": true, "started_at": DictationStore.stamp(session.startedAt)],
                                 to: session.dir.appendingPathComponent("session.json"))
            log.info("dictation: cancelled")
        }
    }

    func finish() {
        guard let session = current, let recorder else { return }
        current = nil
        self.recorder = nil
        overlay.show(caption: "recognizing…", spinning: true, symbol: "waveform")

        queue.async { [weak self] in
            let duration = recorder.stop()
            var record: [String: Any] = [
                "started_at": DictationStore.stamp(session.startedAt),
                "app": session.app.localizedName ?? "",
                "bundle_id": session.app.bundleIdentifier ?? "",
                "recording_seconds": duration,
            ]
            defer { DictationStore.write(record, to: session.dir.appendingPathComponent("session.json")) }
            let done = { DispatchQueue.main.async { self?.overlay.hide() } }

            guard duration >= 0.4 else {
                record["skipped"] = "too short"
                log.info("dictation: \(duration, privacy: .public)s is too short to hold speech")
                return done()
            }
            let heard: Whisper.Heard
            do {
                let started = Date()
                let wav = session.dir.appendingPathComponent("recording.wav")
                try Whisper.normalise(session.dir.appendingPathComponent("recording.caf"), to: wav)
                try? FileManager.default.removeItem(at: session.dir.appendingPathComponent("recording.caf"))
                let listening = Whisper.Listening(language: "ru", prompt: nil)
                heard = try Whisper.hear(wav, listening, outputBase: session.dir.appendingPathComponent("listen-ru"))
                record["listenings"] = [[
                    "language": listening.language, "prompt": NSNull(), "text": heard.text,
                    "json": heard.json.lastPathComponent, "seconds": Date().timeIntervalSince(started),
                ]]
            } catch {
                record["error"] = String(describing: error)
                log.error("dictation: recognition failed: \(String(describing: error), privacy: .public)")
                return done()
            }
            done()
            guard !heard.text.isEmpty else {
                log.info("dictation: nothing heard")
                return
            }
            log.info("dictation: heard '\(heard.text, privacy: .public)'")
            record.merge(self?.insert(heard.text, session: session) ?? [:]) { $1 }
        }
    }

    /// Types `text` where the user was dictating — unless they've gone elsewhere meanwhile, in
    /// which case it goes to the clipboard rather than into whatever has focus now.
    private func insert(_ text: String, session: Session) -> [String: Any] {
        let front = MainQueue.sync { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard front == session.app.processIdentifier else {
            MainQueue.sync {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            log.info("dictation: \(session.app.localizedName ?? "?", privacy: .public) is no longer in front — copied to the clipboard")
            return ["inserted": NSNull(), "copied": text]
        }
        let field = ContextSnapshot.Field.focused()
        let typed = Self.spaced(text, after: field?.textBeforeCursor)
        Replayer.waitForModifierRelease()
        Replayer.replace(deleteCount: 0, with: typed)
        if let field { followUp.start(dir: session.dir, element: field.element, pid: session.app.processIdentifier) }
        return ["inserted": typed, "inserted_at": DictationStore.stamp(Date())]
    }

    /// A space before the text when it would otherwise run into the word before the cursor.
    private static func spaced(_ text: String, after before: String?) -> String {
        guard let last = before?.last, !last.isWhitespace, !"([{«„\"'/".contains(last),
              let first = text.first, first.isLetter || first.isNumber else { return text }
        return " " + text
    }
}

/// After a dictation is typed, watches the field it went into until the user moves on, and records
/// what the text became. Their edits are the signal phase 1 learns from: some fix what was misheard,
/// some just rewrite the sentence, and telling the two apart comes later.
///
/// The watch ends on a plain Return (in a chat that sends the message, so the field is read just
/// before the app sees the key), when focus leaves the field, at the next dictation, or after five
/// minutes.
final class DictationFollowUp {
    private let queue = DispatchQueue(label: "sweetch.dictation.follow-up")
    // Queue-confined.
    private var watch: Watch?

    private final class Watch {
        let dir: URL
        let element: AXUIElement
        let pid: pid_t
        let startedAt = Date()
        var afterInsert: String?
        var last: String?
        var timer: DispatchSourceTimer?

        init(dir: URL, element: AXUIElement, pid: pid_t) {
            self.dir = dir
            self.element = element
            self.pid = pid
        }
    }

    func start(dir: URL, element: AXUIElement, pid: pid_t) {
        queue.async { [self] in
            close(reason: "next dictation")
            let watch = Watch(dir: dir, element: element, pid: pid)
            self.watch = watch
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // The first read, a beat after typing, is the text as dictated.
            timer.schedule(deadline: .now() + 0.3, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.poll() }
            watch.timer = timer
            timer.resume()
        }
    }

    /// From the event tap, before a plain Return reaches the app.
    func noteReturn() {
        queue.sync { [self] in
            guard let watch else { return }
            AXUIElementSetMessagingTimeout(watch.element, 0.15)
            if let value = AX.string(watch.element, kAXValueAttribute) { watch.last = value }
            close(reason: "return")
        }
    }

    func finish(reason: String) {
        queue.async { [self] in close(reason: reason) }
    }

    private func poll() {
        guard let watch else { return }
        if Date().timeIntervalSince(watch.startedAt) > 300 { return close(reason: "timeout") }
        // Not SelectionConverter.focusedElement: its fallback hops to the main thread, which may be
        // blocked in noteReturn waiting for this queue.
        guard let focused = AX.focusedElement() else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(focused, &pid)
        guard pid == watch.pid, CFEqual(focused, watch.element) else { return close(reason: "focus moved") }
        let value = AX.string(watch.element, kAXValueAttribute)
        if watch.afterInsert == nil { watch.afterInsert = value ?? "" }
        if let value { watch.last = value }
    }

    private func close(reason: String) {
        guard let watch else { return }
        self.watch = nil
        watch.timer?.cancel()
        let excerpt = { (s: String?) -> Any in s.map { String($0.suffix(20_000)) } ?? NSNull() }
        DictationStore.write([
            "ended_by": reason,
            "seconds": Date().timeIntervalSince(watch.startedAt),
            "field_after_insert": excerpt(watch.afterInsert),
            "field_final": excerpt(watch.last),
        ], to: watch.dir.appendingPathComponent("followup.json"))
        log.info("dictation: follow-up closed (\(reason, privacy: .public))")
    }
}

/// Where dictations are kept: one folder each under Application Support, plain files that a script
/// can read.
enum DictationStore {
    static let dir: URL = {
        let d = AppSupport.dir.appendingPathComponent("dictation", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    static func newSessionDir() -> URL {
        let d = dir.appendingPathComponent(nameFormatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func stamp(_ date: Date) -> String {
        ISO8601DateFormatter.string(from: date, timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
    }

    static func write(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            log.error("dictation: could not encode \(url.lastPathComponent, privacy: .public)")
            return
        }
        try? data.write(to: url)
    }
}
