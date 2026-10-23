import AVFoundation
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
    private var preview: AnyObject?   // LivePreview, on macOS 26
    /// A hold handed to an app's own dictation, which we hear too, silently, to compare.
    private var shadow: (session: Session, recorder: AudioRecorder, preview: AnyObject?, target: String)?
    private let shadowQueue = DispatchQueue(label: "sweetch.dictation.shadow")
    /// Only the microphone starting and stopping, never waiting on hearing: a hold that follows the
    /// last one closely starts recording at once, not when the last one's been heard (and its field
    /// watched — up to ten seconds for a shadow), which cut off its first words.
    private let microphone = DispatchQueue(label: "sweetch.dictation.microphone")
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
        /// The focused field's whole text as the hold began.
        private(set) var fieldValue: String?

        init(app: NSRunningApplication, dir: URL) {
            contextReady.enter()
            prefixReady.enter()
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { prefixReady.leave() }
                // After the Backspace that took back the held space has landed.
                usleep(100_000)
                let started = Date()
                let field = ContextSnapshot.Field.focused()
                fieldValue = field?.value
                let context = ContextSnapshot.capture(app: app, field: field, into: dir)
                self.context = context
                contextReady.leave()
                let gathered = Date().timeIntervalSince(started)
                let prefix = Prefix.build(from: context)
                self.prefix = prefix
                DictationStore.write([
                    "spoken": prefix.spoken, "preceding": prefix.preceding ?? NSNull(),
                    "context_seconds": gathered, "seconds": Date().timeIntervalSince(started),
                ], to: dir.appendingPathComponent("prefix.json"))
                log.info("dictation: prefix ready in \(Date().timeIntervalSince(started), privacy: .public)s — \(shown(prefix.spoken), privacy: .public)")
            }
        }

        /// The field as it was, once the context has been read (it's read first).
        func fieldBefore(waiting seconds: TimeInterval) -> String? {
            contextReady.wait(timeout: .now() + seconds) == .success ? fieldValue : nil
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
        // Private: nothing recorded, captured, sent or kept — and the user sees why.
        if let reason = Privacy.check(app) {
            followUp.abandon()
            overlay.flash("private — dictation off", detail: reason.text)
            log.info("dictation: private, not started")
            return false
        }
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
        if #available(macOS 26.0, *) {
            let overlay = self.overlay
            let preview = LivePreview { [weak self] text in
                guard self?.preview != nil else { return }   // a late word after release mustn't come back
                overlay.showDetail(text)
            }
            recorder.onBuffer = { preview.append($0) }
            self.preview = preview
        }
        overlay.show(caption: "listening…", spinning: false, symbol: "mic.fill")
        log.info("dictation: listening in \(app.bundleIdentifier ?? "?", privacy: .public) → \(dir.lastPathComponent, privacy: .public)")

        microphone.async { [overlay] in
            do {
                try recorder.start(to: dir.appendingPathComponent("recording.caf"))
            } catch {
                log.error("dictation: recording failed to start: \(String(describing: error), privacy: .public)")
                Self.restartIfMicrophoneLost(error, overlay: overlay)
            }
        }
        return true
    }

    /// A plain Return is about to reach the app (event-tap thread).
    func noteReturn() {
        followUp.noteReturn()
    }

    private func cancelPreview() {
        if #available(macOS 26.0, *) { (preview as? LivePreview)?.cancel() }
        preview = nil
    }

    /// Stops the preview listening and hands back a way to its final words, for the recogniser.
    private func finishPreview() -> (TimeInterval) -> String? {
        defer { preview = nil }
        if #available(macOS 26.0, *), let preview = preview as? LivePreview {
            preview.finish()
            return { preview.transcript(waiting: $0) }
        }
        return { _ in nil }
    }

    func cancel() {
        guard let session = current, let recorder else { return }
        current = nil
        self.recorder = nil
        cancelPreview()
        overlay.hide()
        microphone.async {
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
        let previewText = finishPreview()   // its last words stay on screen while whisper works
        overlay.show(caption: "recognizing…", spinning: true, symbol: "waveform")

        microphone.async { [weak self] in
            let duration = recorder.stop()
            self?.queue.async { [weak self] in
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
                        return (ready.prefix, ready.context, previewText(0.2))
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
                log.info("dictation: heard '\(shown(heard.text), privacy: .public)' from \(shown(heard.versions.map(\.text)), privacy: .public)")
                record.merge(self?.insert(heard.text, session: session) ?? [:]) { $1 }
            }
        }
    }

    /// The microphone there but this process unable to use it ('!dev', canPerformIO false): on
    /// 21 Oct every hold failed so for two hours after the audio devices changed (the iPhone's
    /// microphone came in reach), while a new process recorded at once — a fresh engine per hold
    /// didn't help. Under the watchdog, the app starts again (a failing exit brings it back).
    private static func restartIfMicrophoneLost(_ error: Error, overlay: LoaderOverlay) {
        guard (error as NSError).code == 560227702, Watchdog.isInstalled else { return }
        log.error("dictation: microphone lost to this process — restarting")
        DispatchQueue.main.async {
            overlay.flash("microphone lost — restarting", detail: "hold again in a moment", symbol: "mic.slash")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                TypingLog.shared.flushNow()
                CrashWatch.markCleanExit()
                exit(1)
            }
        }
    }

    // MARK: - Shadowing an app's own dictation

    /// The hold went to `target`'s own dictation (Claude desktop, Claude Code). Record it as well,
    /// with no HUD, so what we'd have heard can be set beside what the app wrote. False when we can't
    /// listen — no prompts are raised for this.
    func beginShadow(app: NSRunningApplication, target: String) -> Bool {
        guard Privacy.check(app) == nil else { return false }   // nothing of a private context kept
        guard Whisper.missing() == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { return false }
        let dir = DictationStore.newSessionDir()
        let session = Session(dir: dir, app: app, startedAt: Date(), prepared: Prepared(app: app, dir: dir), spaceSelected: false)
        let recorder = AudioRecorder()
        var preview: AnyObject?
        if #available(macOS 26.0, *) {
            let live = LivePreview { _ in }
            recorder.onBuffer = { live.append($0) }
            preview = live
        }
        shadow = (session, recorder, preview, target)
        log.info("dictation: shadowing \(target, privacy: .public) → \(dir.lastPathComponent, privacy: .public)")
        microphone.async {
            do { try recorder.start(to: dir.appendingPathComponent("recording.caf")) } catch {
                log.error("dictation: shadow recording failed to start: \(String(describing: error), privacy: .public)")
            }
        }
        return true
    }

    /// Space came up: hear what we recorded, and watch the field for what the app writes.
    func finishShadow() {
        guard let (session, recorder, preview, target) = shadow else { return }
        shadow = nil
        // What the app writes isn't known yet: whether it ends with a period is read off the field
        // when the key comes.
        markAfter = MarkAfter(dir: session.dir, text: nil, pid: session.app.processIdentifier, at: Date())
        let held = Date().timeIntervalSince(session.startedAt)
        var appleText: (TimeInterval) -> String? = { _ in nil }
        if #available(macOS 26.0, *), let live = preview as? LivePreview {
            live.finish()
            appleText = { live.transcript(waiting: $0) }
        }

        // What the app writes, watched while we hear it ourselves.
        let theirs = Box()
        let watched = DispatchGroup()
        watched.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { watched.leave() }
            let before = session.prepared.fieldBefore(waiting: 2) ?? ""
            theirs.value = Theirs.watch(after: before, in: session.app.processIdentifier, dir: session.dir)
        }

        microphone.async { [shadowQueue] in
            let duration = recorder.stop()
            shadowQueue.async {
                var record: [String: Any] = [
                    "handoff": target, "shadow": true,
                    "started_at": DictationStore.stamp(session.startedAt),
                    "app": session.app.localizedName ?? "", "bundle_id": session.app.bundleIdentifier ?? "",
                    "hold_seconds": held, "recording_seconds": duration,
                ]
                do {
                    let started = Date()
                    let wav = session.dir.appendingPathComponent("recording.wav")
                    try Whisper.normalise(session.dir.appendingPathComponent("recording.caf"), to: wav)
                    try? FileManager.default.removeItem(at: session.dir.appendingPathComponent("recording.caf"))
                    let settled = try Hearing.hear(wav, dir: session.dir) {
                        let ready = session.prepared.take(waiting: 0.3)
                        return (ready.prefix, ready.context, appleText(0.2))
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
                }
                watched.wait()
                record["theirs"] = theirs.value ?? NSNull()
                // What the app wrote, ours to offer its words' alternatives for too.
                if let written = theirs.value { WordMenu.shared.inserted(dir: session.dir, text: written, pid: session.app.processIdentifier) }
                DictationStore.write(record, to: session.dir.appendingPathComponent("session.json"))
                log.info("dictation: \(target, privacy: .public) wrote '\(shown(theirs.value), privacy: .public)'; we heard '\(shown(record["text"] as? String), privacy: .public)'")
            }
        }
    }

    /// A dictation just typed that ends with a period — or one the app wrote itself (`text` nil) —
    /// until the next key or click.
    private struct MarkAfter {
        let dir: URL
        let text: String?
        let pid: pid_t
        let at: Date
    }
    private let markLock = NSLock()
    private var _markAfter: MarkAfter?
    /// Set off the main thread (after hearing), read on the tap's.
    private var markAfter: MarkAfter? {
        get { markLock.withLock { _markAfter } }
        set { markLock.withLock { _markAfter = newValue } }
    }

    /// From the event tap, every real key press before anything else sees it. «?», «!» or «)» right
    /// after a dictation that ended with a period — nothing pressed or clicked between — takes the
    /// period's place: the period was a guess, and this is what the sentence ends with. Kept beside
    /// the dictation (`mark.json`), to learn a question's intonation from. True: the key is eaten,
    /// and the period and the mark are typed in its stead.
    func takeMark(_ event: CGEvent) -> Bool {
        guard let mark = markAfter else { return false }
        markAfter = nil
        guard Date().timeIntervalSince(mark.at) < 120,
              event.flags.intersection([.maskCommand, .maskControl]).isEmpty,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return false }
        var length = 0
        var chars: [UniChar] = [0, 0, 0, 0]
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        let typed = String(utf16CodeUnits: chars, count: length)
        guard ["?", "!", ")"].contains(typed),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == mark.pid else { return false }
        let heard = mark.text ?? Self.textBeforeCursor()
        guard let heard, heard.hasSuffix(".") else { return false }
        DispatchQueue.global(qos: .userInteractive).async {
            Replayer.replace(deleteCount: 1, with: typed)
        }
        DictationStore.write(["mark": typed, "heard": String(heard.suffix(300)), "theirs": mark.text == nil, "after_seconds": Date().timeIntervalSince(mark.at)],
                             to: mark.dir.appendingPathComponent("mark.json"))
        TypingLog.shared.note("heard-mark", ["mark": typed])
        log.info("dictation: '\(typed, privacy: .public)' in place of the period")
        return true
    }

    /// What's before the cursor in the focused field, read while the key waits — an app's own
    /// dictation (Claude's) writes there without us. In Claude Code's terminal, its input box.
    private static func textBeforeCursor() -> String? {
        guard let element = AX.focusedElement() else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.15)
        guard let value = AX.string(element, kAXValueAttribute) else { return nil }
        if let box = Theirs.claudeCodeInput(value) { return box.trimmingCharacters(in: .whitespaces) }
        let ns = value as NSString
        guard let selection = AX.range(element, kAXSelectedTextRangeAttribute), selection.length == 0,
              selection.location <= ns.length else { return nil }
        return ns.substring(to: selection.location)
    }

    /// A click: the cursor may be anywhere now.
    func dropMark() { markAfter = nil }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
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
        WordMenu.shared.inserted(dir: session.dir, text: typed, pid: session.app.processIdentifier)
        markAfter = typed.hasSuffix(".") ? MarkAfter(dir: session.dir, text: text, pid: session.app.processIdentifier, at: Date()) : nil
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

    /// Private now: the watch ends without writing what the field held.
    func abandon() {
        queue.async { [self] in
            watch?.timer?.cancel()
            watch = nil
        }
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

    /// Writes with every secret in it masked (Secrets.swift) — nothing kept holds one.
    static func write(_ object: [String: Any], to url: URL) {
        var kinds: [String] = []
        let object = Secrets.mask(object, kinds: &kinds)
        if !kinds.isEmpty { log.info("dictation: masked \(kinds.count) secret(s) in \(url.lastPathComponent, privacy: .public)") }
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
