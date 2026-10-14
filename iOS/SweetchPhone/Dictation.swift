import ActivityKit
import AVFoundation
import UIKit

/// One dictation at a time: the microphone recorded to a 16 kHz WAV, the words shown live in the
/// Dynamic Island, and on stop the recording sent to sweetch on the Mac, which hears it the way it
/// hears a hold of Space there. The text lands on the clipboard.
///
/// Started and stopped by the Action Button through `ToggleDictationIntent`, which runs in the
/// background — the app never comes to the front.
@MainActor
final class Dictation: ObservableObject {
    static let shared = Dictation()

    enum Phase: Equatable {
        case idle, listening, recognizing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var preview = ""
    @Published private(set) var last: String?
    @Published private(set) var lastSeconds: Double?
    @Published private(set) var problem: String?

    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var recording: URL?
    private var startedAt = Date()
    private var live: LivePreview?
    private var activity: Activity<DictationActivity>?
    /// The context sent while the user speaks; its id goes with the recording.
    private var context: Task<String?, Never>?

    private nonisolated static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    /// Starts when idle, stops when listening. True when it started.
    func toggle() async throws -> Bool {
        switch phase {
        case .idle:
            try start()
            return true
        case .listening:
            await stop()
            return false
        case .recognizing:
            return false
        }
    }

    func start() throws {
        guard phase == .idle else { return }
        problem = nil
        preview = ""
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw Failure("no microphone input")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let live = LivePreview { [weak self] text in
            Task { @MainActor in self?.heardSoFar(text) }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: Self.tap(live: live, converter: converter, file: file))
        engine.prepare()
        try engine.start()

        self.engine = engine
        self.file = file
        self.recording = url
        self.live = live
        startedAt = Date()
        phase = .listening
        activity = try? Activity.request(attributes: DictationActivity(),
                                         content: .init(state: .init(phase: .listening, text: ""), staleDate: nil))
    }

    /// The screenshot the Shortcut takes right after starting: sent at once, so the Mac reads it
    /// while the user is still speaking.
    func attach(screenshot: Data) {
        guard phase == .listening, context == nil else { return }
        let jpeg = UIImage(data: screenshot)?.jpegData(compressionQuality: 0.8) ?? screenshot
        context = Task { try? await Server.current.context(screenshot: jpeg, fieldBefore: nil) }
    }

    func stop() async {
        guard phase == .listening, let engine, let recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        file = nil   // closes the WAV
        phase = .recognizing
        live?.finish()
        await show(.recognizing, preview)

        let apple = await live?.transcript(waiting: 0.3)
        live = nil
        let contextID = await context?.value
        context = nil
        let started = Date()
        do {
            let text = try await Server.current.hear(try Data(contentsOf: recording), contextID: contextID, apple: apple)
            lastSeconds = Date().timeIntervalSince(started)
            last = text
            if !text.isEmpty { UIPasteboard.general.string = text }
            await show(.done, text.isEmpty ? "Nothing heard" : text)
        } catch {
            problem = error.localizedDescription
            if let apple, !apple.isEmpty {   // the Mac is out of reach: the phone's own hearing will do
                last = apple
                UIPasteboard.general.string = apple
                await show(.done, apple)
            } else {
                await show(.failed, error.localizedDescription)
            }
        }
        try? FileManager.default.removeItem(at: recording)
        self.recording = nil
        phase = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let ending = activity
        activity = nil
        Task {
            try? await Task.sleep(for: .seconds(4))
            await ending?.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func heardSoFar(_ text: String) {
        guard phase == .listening else { return }
        preview = text
        Task { await show(.listening, text) }
    }

    private func show(_ phase: DictationActivity.ContentState.Phase, _ text: String) async {
        await activity?.update(.init(state: .init(phase: phase, text: String(text.suffix(200))), staleDate: nil))
    }

    /// Made outside the main actor: the tap runs on the audio thread.
    private nonisolated static func tap(live: LivePreview, converter: AVAudioConverter, file: AVAudioFile) -> AVAudioNodeTapBlock {
        { buffer, _ in
            live.append(buffer)
            guard let converted = convert(buffer, with: converter) else { return }
            try? file.write(from: converted)
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

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}
