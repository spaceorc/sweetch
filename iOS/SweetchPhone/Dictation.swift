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
    @Published private(set) var problem: String?

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

    /// Starts when not listening, stops when listening. Nil when it started; what was heard when it
    /// stopped (empty when nothing was). `waitingForScreenshot`: a Shortcut is about to attach one.
    func toggle(waitingForScreenshot: Bool = true) async throws -> String? {
        switch phase {
        case .idle:
            do {
                try start(waitingForScreenshot: waitingForScreenshot)
            } catch {
                problem = error.localizedDescription
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
        server = Task { await Server.reachable() }
        screenshot = nil
        sendContext(waitingForScreenshot: waitingForScreenshot)
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
        microphoneOff()
        // The experiment: heard on the phone too, alongside the Mac, while the app is open (iOS gives
        // an app in the background no GPU).
        if PhoneWhisper.shared.enabled, UIApplication.shared.applicationState == .active {
            let audioSeconds = Double((try? AVAudioFile(forReading: recording))?.length ?? 0) / 16_000
            PhoneWhisper.shared.hear(recording) { text, seconds in
                // To the Mac's log beside the Mac's own hearing of the same recording.
                Task {
                    let event: [String: Any] = ["e": "phone-whisper", "t": Date().timeIntervalSince1970, "run": "app",
                                                "text": text, "seconds": seconds, "audio_seconds": audioSeconds]
                    _ = await Server.reachable()?.keyboardLog([event], batch: UUID().uuidString)
                }
            }
        }
        phase = .recognizing
        live?.finish()
        defer { live = nil }
        await show(.recognizing, preview)

        let apple = await live?.transcript(waiting: 0.3)
        let contextID = await context?.value
        context = nil
        defer { server = nil }
        let started = Date()
        do {
            guard let mac = await server?.value else { throw Failure("the Mac is out of reach") }
            let audio = try Data(contentsOf: recording)
            let text: String
            do {
                text = try await mac.hear(audio, contextID: contextID, apple: apple)
            } catch let error as URLError {
                // The Mac went away while hearing: the next one hears it, without the screen's context
                // (that stayed on the first).
                Server.markDown(mac.mac)
                guard let next = await Server.reachable(), next.mac != mac.mac else { throw error }
                text = try await next.hear(audio, contextID: nil, apple: apple)
            }
            lastSeconds = Date().timeIntervalSince(started)
            last = text
            copyInFront(text)
        } catch {
            problem = error.localizedDescription
            if let apple, !apple.isEmpty {   // the Mac is out of reach: the phone's own hearing will do
                last = apple
                copyInFront(apple)
            }
        }
        try? FileManager.default.removeItem(at: recording)
        self.recording = nil
        await endActivity(showing: .init(phase: problem == nil || last != nil ? .done : .failed,
                                         text: last.map { $0.isEmpty ? "Nothing heard" : $0 } ?? problem ?? ""))
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
