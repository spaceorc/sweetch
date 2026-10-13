import Cocoa
import ApplicationServices

/// sweetch's own dictation, for apps without one: hold Space in a text field, speak, release.
///
/// While the user speaks, what's in front of them is gathered (`ContextSnapshot`) and the fast model
/// writes the recognition prefix from it (`Prefix`). On release the recording is heard several
/// ways and settled into what was said (`Hearing`), with the whole context read again. Every dictation leaves a folder in `DictationStore.dir` with the
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
        let prepared: Prepared
        /// The space the held key typed is selected, to be typed over — or deleted if nothing is.
        let spaceSelected: Bool
    }

    /// The context and the prefix, made while the user speaks. The recogniser doesn't wait long for
    /// them: what was said matters more than how well it was primed.
    private final class Prepared {
        private let contextReady = DispatchGroup()
        private let prefixReady = DispatchGroup()
        private(set) var context: ContextSnapshot.Gathered?
        private(set) var prefix: Prefix?

        init(app: NSRunningApplication, dir: URL) {
            contextReady.enter()
            prefixReady.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { prefixReady.leave() }
                // After the Backspace that took back the held space has landed.
                usleep(100_000)
                let started = Date()
                let context = ContextSnapshot.capture(app: app, field: ContextSnapshot.Field.focused(), into: dir)
                self.context = context
                contextReady.leave()
                let gathered = Date().timeIntervalSince(started)
                let prefix = Prefix.build(from: context)
                self.prefix = prefix
                DictationStore.write([
                    "spoken": prefix.spoken, "preceding": prefix.preceding ?? NSNull(),
                    "context_seconds": gathered, "seconds": Date().timeIntervalSince(started),
                ], to: dir.appendingPathComponent("prefix.json"))
                log.info("dictation: prefix ready in \(Date().timeIntervalSince(started), privacy: .public)s — \(prefix.spoken, privacy: .public)")
            }
        }

        /// Whatever is ready within `seconds`; nil for what isn't.
        func take(waiting seconds: TimeInterval) -> (prefix: Prefix?, context: ContextSnapshot.Gathered?) {
            let deadline = DispatchTime.now() + seconds
            let prefix = prefixReady.wait(timeout: deadline) == .success ? self.prefix : nil
            let context = contextReady.wait(timeout: deadline) == .success ? self.context : nil
            return (prefix, context)
        }
    }

    init(overlay: LoaderOverlay) {
        self.overlay = overlay
    }

    /// False when the hold can't be recorded — the caller then lets Space be Space.
    func begin(app: NSRunningApplication, spaceSelected: Bool) -> Bool {
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
        let session = Session(dir: dir, app: app, startedAt: Date(), prepared: Prepared(app: app, dir: dir),
                              spaceSelected: spaceSelected)
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
            Self.dropSelectedSpace(session)
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
            defer { if record["inserted"] == nil { Self.dropSelectedSpace(session) } }

            guard duration >= 0.4 else {
                record["skipped"] = "too short"
                log.info("dictation: \(duration, privacy: .public)s is too short to hold speech")
                return done()
            }
            let settled: Hearing.Settled?
            do {
                let started = Date()
                let wav = session.dir.appendingPathComponent("recording.wav")
                try Whisper.normalise(session.dir.appendingPathComponent("recording.caf"), to: wav)
                try? FileManager.default.removeItem(at: session.dir.appendingPathComponent("recording.caf"))
                settled = try Hearing.hear(wav, dir: session.dir) {
                    // The listening without a prefix has run by now; the prefix gets a moment more.
                    let ready = session.prepared.take(waiting: 0.3)
                    if ready.prefix == nil { log.info("dictation: prefix not ready — hearing without it") }
                    return ready
                }
                record["seconds"] = Date().timeIntervalSince(started)
                if let settled {
                    record["listenings"] = settled.versions.flatMap(\.members).map(\.record)
                    record["versions"] = settled.versions.map(\.text)
                    record["settlement"] = settled.settlement ?? NSNull()
                    record["text"] = settled.text
                }
            } catch {
                record["error"] = String(describing: error)
                log.error("dictation: recognition failed: \(String(describing: error), privacy: .public)")
                return done()
            }
            done()
            guard let heard = settled, !heard.text.isEmpty else {
                log.info("dictation: nothing heard")
                return
            }
            log.info("dictation: heard '\(heard.text, privacy: .public)' from \(heard.versions.map(\.text), privacy: .public)")
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

    /// Nothing will be typed over the selected space: delete it, if the user is still there.
    private static func dropSelectedSpace(_ session: Session) {
        guard session.spaceSelected,
              MainQueue.sync({ NSWorkspace.shared.frontmostApplication?.processIdentifier }) == session.app.processIdentifier else { return }
        Replayer.waitForModifierRelease()
        Replayer.postKeyPair(keyCode: 51, flags: [])   // Backspace deletes just the selection
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

    /// Posted on the main thread whenever a dictation's files change.
    static let changed = Notification.Name("sweetch.dictations.changed")

    static func newSessionDir(at date: Date = Date()) -> URL {
        let d = dir.appendingPathComponent(nameFormatter.string(from: date), isDirectory: true)
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
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: url) }
    }

    /// A hold that went to an app's own dictation, kept beside ours so the history shows both.
    static func recordHandoff(app: NSRunningApplication, to target: String, startedAt: Date, seconds: TimeInterval) {
        let appName = app.localizedName ?? ""
        let bundleID = app.bundleIdentifier ?? ""
        DispatchQueue.global(qos: .utility).async {
            write(["handoff": target, "app": appName, "bundle_id": bundleID,
                   "started_at": stamp(startedAt), "hold_seconds": seconds],
                  to: newSessionDir(at: startedAt).appendingPathComponent("session.json"))
        }
    }
}
