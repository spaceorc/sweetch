import ActivityKit
import AVFoundation
import UIKit

/// Dictation on the phone: the microphone recorded to a 16 kHz WAV, the words shown live in the
/// Dynamic Island, and on stop the recording sent to sweetch on the Mac, which hears it the way it
/// hears a hold of Space there. The keyboard types the text; the Shortcut copies it.
///
/// Started by the Action Button (`ToggleDictationIntent`, in the background), by the keyboard's
/// microphone key, or in the app. After a dictation the microphone stays on — warm, recording
/// nothing — for a while, so the keyboard's key can start the next one at once: a keyboard can't
/// listen itself, and an app in the background can't turn the microphone on.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        /// The microphone is off.
        case idle
        /// On, recording nothing: the next start is instant.
        case warm
        case listening
        case recognizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview = ""
    @Published private(set) var last: String?
    @Published private(set) var lastSeconds: Double?
    @Published private(set) var problem: String?

    /// How long the microphone stays warm after a dictation, in minutes: a setting, off by default.
    static let warmMinutesKey = "warmMinutes"
    static var warmFor: Duration { .seconds(60 * UserDefaults.standard.integer(forKey: warmMinutesKey)) }

    private var engine: AVAudioEngine?
    private let tap = Tap()
    private var recording: URL?
    private var live: LivePreview?
    private var activity: Activity<DictationActivity>?
    private var cooling: Task<Void, Never>?
    /// The context sent while the user speaks; its id goes with the recording.
    private var context: Task<String?, Never>?
    /// Which of the Mac's addresses answers, found while the user speaks.
    private var server: Task<Server?, Never>?
    private var screenshot: Data?

    private nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private init() {
        Signal.toggle.observe { [weak self] in
            Task { _ = try? await self?.toggle(waitingForScreenshot: false) }
        }
        Signal.ping.observe { [weak self] in
            guard let self else { return }
            switch phase {
            case .warm: Signal.warm.post()
            case .listening: Signal.listening.post()
            case .recognizing: Signal.warm.post()
            case .idle: Signal.cold.post()
            }
        }
        // Locked, the phone needs no warm microphone: it goes off at once. A dictation in progress
        // goes on — the Action Button works on the lock screen too.
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.locked() }
        }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { Dictation.shared.locked() } }
        }, "com.apple.springboard.lockcomplete" as CFString, nil, .deliverImmediately)
    }

    private func locked() {
        Trace.note("locked in \(phase)")
        guard phase == .warm else { return }
        Task { await coolDown(showing: nil) }
    }

    /// Starts when not listening, stops when listening. Nil when it started; what was heard when it
    /// stopped (empty when nothing was). `waitingForScreenshot`: a Shortcut is about to attach one.
    func toggle(waitingForScreenshot: Bool = true) async throws -> String? {
        Trace.note("toggle in \(phase)")
        switch phase {
        case .idle, .warm:
            do {
                try start(waitingForScreenshot: waitingForScreenshot)
            } catch {
                Trace.note("start failed: \(error)")
                problem = error.localizedDescription
                await coolDown(showing: .init(phase: .failed, text: error.localizedDescription))
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
        problem = nil
        preview = ""
        cooling?.cancel()
        try warmUp()

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
        server = Task { await Server.reachable() }
        screenshot = nil
        sendContext(waitingForScreenshot: waitingForScreenshot)
        phase = .listening
        Signal.listening.post()
        Task { await show(.listening, "") }
        Trace.note("listening")
    }

    /// The microphone on, recording nothing — unless it is already.
    private func warmUp() throws {
        guard engine == nil else { return }
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
        Trace.note("microphone on")
    }

    /// The screenshot the Shortcut takes right after starting: the context waits a moment for it.
    func attach(screenshot: Data) {
        Trace.note("screenshot: \(screenshot.count) bytes")
        guard phase == .listening else { return }
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
            guard let mac = await server?.value else { return nil }
            return try? await mac.context(screenshot: self?.screenshot, fieldBefore: nil)
        }
    }

    func stop() async {
        last = nil
        guard phase == .listening, let recording else { return }
        tap.end()   // closes the WAV: only then are its samples and sizes written
        phase = .recognizing
        Signal.warm.post()
        live?.finish()
        await show(.recognizing, preview)

        let apple = await live?.transcript(waiting: 0.3)
        live = nil
        let contextID = await context?.value
        context = nil
        defer { server = nil }
        let started = Date()
        do {
            guard let mac = await server?.value else { throw Failure("the Mac is out of reach") }
            let text = try await mac.hear(try Data(contentsOf: recording), contextID: contextID, apple: apple)
            lastSeconds = Date().timeIntervalSince(started)
            Trace.note("heard in \(lastSeconds ?? 0)s: \(text)")
            last = text
            copyInFront(text)
            await show(.done, text.isEmpty ? "Nothing heard" : text)
        } catch {
            problem = error.localizedDescription
            Trace.note("hearing failed: \(error)")
            if let apple, !apple.isEmpty {   // the Mac is out of reach: the phone's own hearing will do
                last = apple
                copyInFront(apple)
                await show(.done, apple)
            } else {
                await show(.failed, error.localizedDescription)
            }
        }
        try? FileManager.default.removeItem(at: recording)
        self.recording = nil
        // A dictation finished on the lock screen doesn't warm the microphone either.
        guard Self.warmFor > .zero, UIApplication.shared.isProtectedDataAvailable else {
            await coolDown(showing: .init(phase: .done, text: last ?? ""))
            return
        }
        phase = .warm
        cooling = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            await self?.show(.warm, "")
            try? await Task.sleep(for: Self.warmFor)
            guard !Task.isCancelled else { return }
            await self?.coolDown(showing: nil)
        }
    }

    /// The microphone off and the Live Activity gone.
    func coolDown(showing final: DictationActivity.ContentState?) async {
        cooling?.cancel()
        cooling = nil
        tap.end()
        live?.finish()
        live = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        phase = .idle
        Signal.cold.post()
        let ending = activity
        activity = nil
        if let final {
            await ending?.end(.init(state: final, staleDate: nil), dismissalPolicy: .after(.now + 4))
        } else {
            await ending?.end(nil, dismissalPolicy: .immediate)
        }
        Trace.note("microphone off")
    }

    /// The clipboard only takes text from the app in front; in the background the Shortcut copies it.
    private func copyInFront(_ text: String) {
        if !text.isEmpty, UIApplication.shared.applicationState == .active { UIPasteboard.general.string = text }
    }

    private func heardSoFar(_ text: String) {
        guard phase == .listening else { return }
        preview = text
        Task { await show(.listening, text) }
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
        var converter: AVAudioConverter?

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
