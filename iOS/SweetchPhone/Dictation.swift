import ActivityKit
import AVFoundation
import UIKit

/// Dictation on the phone: the microphone recorded to a 16 kHz WAV, the words shown live in the
/// Dynamic Island, and on stop the recording sent to sweetch on the Mac, which hears it the way it
/// hears a hold of Space there. The keyboard types the text; the Shortcut copies it.
///
/// Started by the Action Button (`ToggleDictationIntent`, in the background) — whose Shortcut also
/// sends a screenshot — or in the app. The microphone is on only while listening.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle
        case listening
        case recognizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview = ""
    @Published private(set) var last: String?
    @Published private(set) var lastSeconds: Double?
    /// The last dictation as the history knows it — its folder on the Mac, or on the phone — and
    /// how it was heard: for a talk about it straight from the dictation screen.
    @Published private(set) var lastItem: DictationItem?
    /// Asked from the dictation screen: a talk about this one, once the screen is down.
    @Published var talkAbout: DictationItem?
    @Published private(set) var problem: String?
    /// The big dictation screen is up: opened from the keyboard's microphone.
    @Published var screen = false {
        // Closed: incognito was the screen's — an Action Button dictation after it is as usual.
        didSet { if !screen, phase == .idle { incognito = false; inApp = false } }
    }
    /// The screen was opened by the keyboard in sweetch's own talk about a dictation: nothing to
    /// swipe back to — what's heard is put in the talk's field from here (`insertion`).
    @Published var inApp = false
    /// Heard for the talk's field: taken by the talk, which puts it in its field — the talk it was
    /// dictated in (`insertionFor`, the dictation it's about), now or when it's open again.
    @Published var insertion: String?
    var insertionFor: String?
    /// `insertionFor` a field of the app's other than a talk: the keyboard types it there.
    static let anyField = "field"

    /// The keyboard's microphone in a field of the app's own (not a talk — that one dictates
    /// itself): heard in place, no screen; the field gets it through the keyboard.
    func dictateInField() {
        guard phase == .idle, !screen else { return }
        var context = SharedState.inAppContext ?? [:]
        context["host_app"] = "Sweetch"
        keyboard = context
        inApp = true
        insertionFor = Self.anyField
        Task { _ = try? await toggle(waitingForScreenshot: false, source: "field-mic") }
    }
    /// What the keyboard knew when its microphone opened the dictation: the context, in place of a
    /// screenshot. Taken by the next dictation.
    var keyboard: [String: Any]?
    /// Incognito: the keyboard's microphone opened the dictation while the keyboard was incognito.
    /// Heard on the phone alone — whisper here, or Apple's hearing — with no context, no model, no
    /// Mac; nothing kept (no folder, no log, not on the clipboard), nothing shown on the lock
    /// screen; the text reaches the keyboard on the phone. Taken by the next dictation.
    @Published var incognito = false

    private var engine: AVAudioEngine?
    private let tap = Tap()
    private var recording: URL?
    private var live: LivePreview?
    private var activity: Activity<DictationActivity>?
    /// The context sent while the user speaks; its id goes with the recording.
    private var context: Task<String?, Never>?
    /// Which of the Mac's addresses answers, found while the user speaks.
    private var server: Task<Server?, Never>?
    private var screenshot: Data?

    private nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private init() {}

    /// How loud the microphone is now, 0…1: for the screen's meter.
    nonisolated var level: Float { tap.level }

    /// A test: hear every dictation on the phone, as if no Mac answered.
    static var phoneOnly: Bool { UserDefaults.standard.bool(forKey: "phoneOnly") }

    /// Starts when not listening, stops when listening. Nil when it started; what was heard when it
    /// stopped (empty when nothing was). `waitingForScreenshot`: a Shortcut is about to attach one.
    /// `source`: what asked — for the log: a second recording no one meant to start came after a
    /// dictation twice on 22 Oct, and which of the ways in started it wasn't known.
    func toggle(waitingForScreenshot: Bool = true, source: String) async throws -> String? {
        noteAction(phase == .idle ? "start" : "stop", source: source)
        switch phase {
        case .idle:
            do {
                try start(waitingForScreenshot: waitingForScreenshot)
            } catch {
                problem = error.localizedDescription
                noteAction("failed", source: source, ["error": error.localizedDescription])
                microphoneOff()
                await endActivity(showing: .init(phase: .failed, text: error.localizedDescription))
                throw error
            }
            return nil
        case .listening:
            await stop()
            return last ?? ""
        case .recognizing:
            return ""
        }
    }

    private func start(waitingForScreenshot: Bool) throws {
        // The Action Button while the keyboard is incognito (by hand, or in a private tab): this
        // one is too — no screenshot, nothing to the Mac, nothing kept.
        // Not in the app's own talk: its field is the app's, not private whatever the keyboard last said.
        if !screen, !inApp, SharedState.keyboardIncognito { incognito = true }
        problem = nil
        preview = ""
        try microphoneOn()

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let live = LivePreview { [weak self] text in
            Task { @MainActor in self?.heardSoFar(text) }
        }
        tap.begin(file: file, live: live)
        recording = url
        self.live = live
        server = incognito ? nil : Task { await Server.reachable() }
        screenshot = nil
        if !incognito { sendContext(waitingForScreenshot: waitingForScreenshot) }
        phase = .listening
        Task { await show(.listening, "") }
    }

    private func microphoneOn() throws {
        // The Live Activity first: iOS ends an Action Button recording that has none, and checks as
        // soon as the audio session is up.
        if activity == nil {
            do {
                activity = try Activity.request(attributes: DictationActivity(),
                                                content: .init(state: .init(phase: .listening, text: ""), staleDate: nil))
            } catch {
                throw Failure("no Live Activity: \(error.localizedDescription)")
            }
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw Failure("no microphone input")
        }
        tap.converter = converter
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap.block)
        engine.prepare()
        try engine.start()
        self.engine = engine
    }

    /// The screenshot the Shortcut takes right after starting: the context waits a moment for it.
    func attach(screenshot: Data) {
        guard phase == .listening, !incognito else { return }
        self.screenshot = UIImage(data: screenshot)?.jpegData(compressionQuality: 0.8) ?? screenshot
    }

    /// Sent while the user speaks, so the Mac reads the screen and writes the prefix meanwhile: the
    /// screenshot when the Shortcut sends one within a moment, and on the Mac's side the field the
    /// keyboard told it about.
    private func sendContext(waitingForScreenshot: Bool) {
        let server = server
        context = Task { [weak self] in
            if waitingForScreenshot {
                for _ in 0..<30 where self?.screenshot == nil {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard !Dictation.phoneOnly, let mac = await server?.value else {
                // No Mac: the phone works the context out itself, for its own hearing.
                await self?.startLocalContext()
                return nil
            }
            Task { await Credentials.refresh(from: mac) }
            return try? await mac.context(screenshot: self?.screenshot, fieldBefore: nil, keyboard: self?.keyboard)
        }
    }

    /// The phone's own hearing, when no Mac answers: its folder, and the prefix being worked out.
    private var localDir: URL?
    private var localContext: Task<(Prefix?, ContextSnapshot.Gathered), Never>?

    private func startLocalContext() {
        guard PhonePipeline.canHear, localContext == nil else { return }
        let dir = PhonePipeline.newDirectory()
        let shot = screenshot, keyboard = keyboard
        localDir = dir
        localContext = Task.detached { PhonePipeline.context(screenshot: shot, keyboard: keyboard, dir: dir) }
    }

    /// What started or stopped a recording, and how long after the last one ended — to the Mac's log.
    func noteAction(_ action: String, source: String, _ more: [String: Any] = [:]) {
        guard !incognito else { return }
        var event: [String: Any] = ["e": "phone-dictation", "t": Date().timeIntervalSince1970, "run": "app", "action": action,
                                    "source": source, "phase": "\(phase)", "since_last_end": lastEnded.map { Date().timeIntervalSince($0) } ?? -1,
                                    "in_app": inApp, "screen": screen]
        event.merge(more) { _, b in b }
        Task { await PhoneLog.note([event]) }
    }
    private var lastEnded: Date?

    func stop(reason: String? = nil) async {
        if let reason, phase == .listening { noteAction("stop", source: reason) }
        if phase == .listening { lastEnded = Date() }
        last = nil
        lastItem = nil
        guard phase == .listening, let recording else { return }
        tap.end()   // closes the WAV: only then are its samples and sizes written
        microphoneOff()
        // The experiment: heard on the phone too, alongside the Mac, while the app is open (iOS gives
        // an app in the background no GPU).
        if !incognito, PhoneWhisper.shared.enabled, UIApplication.shared.applicationState == .active {
            let audioSeconds = Double((try? AVAudioFile(forReading: recording))?.length ?? 0) / 16_000
            PhoneWhisper.shared.hear(recording) { text, seconds in
                // To the Mac's log beside the Mac's own hearing of the same recording.
                Task {
                    let event: [String: Any] = ["e": "phone-whisper", "t": Date().timeIntervalSince1970, "run": "app",
                                                "text": text, "seconds": seconds, "audio_seconds": audioSeconds]
                    await PhoneLog.note([event])
                }
            }
        }
        phase = .recognizing
        live?.finish()
        defer { live = nil }
        await show(.recognizing, preview)

        let apple = await live?.transcript(waiting: 0.3)
        if incognito {
            let started = Date()
            let text = await Self.hearPrivately(recording) ?? apple ?? ""
            lastSeconds = Date().timeIntervalSince(started)
            last = text
            if inApp, !screen, insertionFor != Self.anyField {
                if !text.isEmpty { insertion = text }
                inApp = false
            } else if !text.isEmpty {
                PhoneServer.shared.publish(text, id: nil)
                inApp = false
            }
            try? FileManager.default.removeItem(at: recording)
            self.recording = nil
            server = nil
            keyboard = nil
            await endActivity(showing: .init(phase: .done, text: "Incognito"))
            if !screen { incognito = false }
            return
        }
        let contextID = await context?.value
        context = nil
        defer { server = nil }
        let started = Date()
        do {
            // No Mac when it started (the phone just woken, the network not up yet — 24 Oct, a talk's
            // dictation heard on the phone alone): asked again now, seconds later.
            var found = await server?.value
            if found == nil, !Self.phoneOnly { found = await Server.reachable() }
            guard !Self.phoneOnly, let mac = found else { throw Failure("the Mac is out of reach") }
            let audio = try Data(contentsOf: recording)
            let text: String
            var id: String?
            do {
                (text, id) = try await mac.hear(audio, contextID: contextID, apple: apple)
            } catch let error as URLError {
                // The Mac went away while hearing: the next one hears it, without the screen's context
                // (that stayed on the first).
                Server.markDown(mac.mac)
                guard let next = await Server.reachable(), next.mac != mac.mac else { throw error }
                (text, id) = try await next.hear(audio, contextID: nil, apple: apple)
            }
            lastSeconds = Date().timeIntervalSince(started)
            last = text
            lastItem = id.flatMap { Self.item(id: $0, text: text, heardOn: "mac", local: false) }
            copyInFront(text)
        } catch {
            // No Mac: the phone hears it the Mac's way, if whisper is here; else Apple's hearing will do.
            if PhonePipeline.canHear {
                if localContext == nil { startLocalContext() }
                let settled = await PhonePipeline.hear(recording, dir: localDir ?? PhonePipeline.newDirectory(),
                                                       apple: apple, context: localContext)
                if let settled {
                    lastSeconds = Date().timeIntervalSince(started)
                    last = settled.text
                    lastItem = localDir.flatMap { Self.item(id: $0.lastPathComponent, text: settled.text, heardOn: "phone", local: true) }
                    copyInFront(settled.text)
                } else {
                    last = ""
                }
            } else {
                problem = error.localizedDescription
                if let apple, !apple.isEmpty {
                    last = apple
                    copyInFront(apple)
                }
                // Kept with its recording all the same: a Mac hears it again once one answers.
                PhonePipeline.keepUnheard(recording, apple: apple, keyboard: keyboard)
            }
        }
        // Heard here, not by a Mac (whose own server tells the keyboard): to the keyboard from here.
        let heardHere = localDir.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("session.json").path) } ?? false
        if let last, heardHere { PhoneServer.shared.publish(last, id: localDir?.lastPathComponent) }
        localContext = nil
        localDir = nil
        keyboard = nil
        Task {
            await PhoneLog.flush()
            await PhoneDictations.upload()
        }
        try? FileManager.default.removeItem(at: recording)
        self.recording = nil
        noteAction("heard", source: "stop", ["chars": last?.count ?? -1, "problem": problem ?? "",
                                            "by": lastItem?.heardOn ?? (problem == nil ? "?" : "none")])
        // Dictated in the app's own talk: to its field. In another field of the app's: to the
        // keyboard there, as from the dictation screen (from the Mac too — the keyboard drops the
        // second of the same words).
        if inApp, !screen {
            if let last, !last.isEmpty {
                if insertionFor == Self.anyField { PhoneServer.shared.publish(last, id: lastItem?.id) } else { insertion = last }
            }
            inApp = false
        }
        await endActivity(showing: .init(phase: problem == nil || last != nil ? .done : .failed,
                                         text: last.map { $0.isEmpty ? "Nothing heard" : $0 } ?? problem ?? ""))
    }

    private static func item(id: String, text: String, heardOn: String, local: Bool) -> DictationItem? {
        DictationItem(["id": id, "t": Date().timeIntervalSince1970, "text": text, "app": "", "device": "iPhone",
                       "heard_on": heardOn, "recording": true, "local": local])
    }

    private func microphoneOff() {
        tap.end()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func endActivity(showing final: DictationActivity.ContentState) async {
        phase = .idle
        let ending = activity
        activity = nil
        await ending?.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 4))
    }

    /// The clipboard only takes text from the app in front; in the background the Shortcut copies it.
    private func copyInFront(_ text: String) {
        if !inApp, !text.isEmpty, UIApplication.shared.applicationState == .active { UIPasteboard.general.string = text }
    }

    private func heardSoFar(_ text: String) {
        guard phase == .listening else { return }
        preview = text
        // Incognito: the words stay on the app's screen, not the lock screen's.
        Task { await show(.listening, incognito ? "" : text) }
    }

    /// Incognito's hearing: whisper on the phone, bare — no prompt, no model after — or nil.
    private nonisolated static func hearPrivately(_ wav: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: PhoneWhisper.modelFile.path), let samples = PhoneWhisper.samples(wav) else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let heard = PhoneWhisper.shared.listen(samples, language: nil, prompt: nil) else { return done.resume(returning: nil) }
                let text = Whisper.withoutRepeat(heard.segments).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: text.isEmpty || Whisper.isPhantom(text) ? nil : text)
            }
        }
    }

    private func show(_ phase: DictationActivity.ContentState.Phase, _ text: String) async {
        await activity?.update(.init(state: .init(phase: phase, text: String(text.suffix(200))), staleDate: nil))
    }

    /// What the microphone's tap does, on the audio thread: while a dictation is on, every buffer
    /// to the live preview and, at 16 kHz, to the WAV; between dictations, nothing.
    private final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var file: AVAudioFile?
        private var live: LivePreview?
        private var loudness: Float = 0
        var converter: AVAudioConverter?

        var level: Float { lock.withLock { file == nil ? 0 : loudness } }

        func begin(file: AVAudioFile, live: LivePreview) {
            lock.withLock {
                converter?.reset()
                self.file = file
                self.live = live
            }
        }

        func end() {
            lock.withLock {
                file?.close()
                file = nil
                live = nil
            }
        }

        var block: AVAudioNodeTapBlock {
            { [self] buffer, _ in
                lock.withLock {
                    guard let file else { return }
                    if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                        var sum: Float = 0
                        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
                        let decibels = 10 * log10(max(sum / Float(buffer.frameLength), 1e-9))
                        loudness = min(1, max(0, (decibels + 55) / 45))
                    }
                    live?.append(buffer)
                    guard let converter, let converted = Dictation.convert(buffer, with: converter) else { return }
                    try? file.write(from: converted)
                }
            }
        }
    }

    private nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
