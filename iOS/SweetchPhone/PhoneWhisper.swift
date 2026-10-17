import AVFoundation
import Foundation
import UIKit
import whisper

/// Whisper on the phone itself — the Mac's engine (whisper.cpp, the same large-v3-turbo model),
/// on the phone's GPU. An experiment: a dictation made in the open app is heard here as well as on
/// the Mac, to see how fast and how well. (iOS gives an app in the background no GPU, so not yet for
/// the Action Button.)
@MainActor
final class PhoneWhisper: ObservableObject {
    static let shared = PhoneWhisper()

    nonisolated static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!
    nonisolated static var modelFile: URL { URL.documentsDirectory.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin") }
    /// The experiment with the Neural Engine: the encoder as Core ML (whisper.cpp finds it beside the
    /// model by name, `…-encoder.mlmodelc`), with the model hard-linked into its own folder so that
    /// only this context takes it — the GPU's and the CPU's stay as they were, to compare.
    nonisolated static var aneFolder: URL { URL.documentsDirectory.appendingPathComponent("ane") }
    nonisolated static var aneModel: URL { aneFolder.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin") }
    nonisolated static var aneEncoder: URL { aneFolder.appendingPathComponent("ggml-large-v3-turbo-encoder.mlmodelc") }
    nonisolated static var hasEncoder: Bool { FileManager.default.fileExists(atPath: aneEncoder.appendingPathComponent("coremldata.bin").path) }

    enum State: Equatable {
        case absent
        case downloading(Double)
        case loading
        case ready
        case failed(String)
    }

    /// `.ready`: the model is here (and loaded once `enabled`).
    @Published private(set) var state: State = FileManager.default.fileExists(atPath: modelFile.path) ? .ready : .absent
    /// The last dictation as heard here: the text, how long it took, and loading the model.
    @Published private(set) var last: (text: String, seconds: Double)?
    @Published var enabled = UserDefaults.standard.bool(forKey: "phoneWhisper") {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "phoneWhisper")
            if enabled { load() }
        }
    }

    private let queue = DispatchQueue(label: "sweetch.phone-whisper", qos: .userInitiated)
    nonisolated(unsafe) private var context: OpaquePointer?
    /// The same model on the CPU, for listening while the app is in the background: loaded when
    /// first needed.
    nonisolated(unsafe) private var cpuContext: OpaquePointer?
    /// The encoder on the Neural Engine (Core ML), the decoder on the CPU: for the background, when
    /// the encoder is here. Loaded with the GPU's — Core ML compiles it for the device on first load,
    /// which may take minutes and had better happen in front.
    nonisolated(unsafe) private var aneContext: OpaquePointer?
    /// How long the last load of the Neural Engine context took.
    @Published private(set) var aneLoadSeconds: Double?
    /// Whether the app is in front, as last seen on the main thread (the GPU is only for then).
    nonisolated(unsafe) var inFront = true
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    private init() {
        if enabled { load() }
        for (name, front) in [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false)] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.inFront = front }
        }
    }

    func fetchModel() {
        guard download == nil else { return }
        state = .downloading(0)
        let task = URLSession.shared.downloadTask(with: Self.modelURL) { [weak self] temporary, _, error in
            let outcome: State
            if let temporary {
                try? FileManager.default.removeItem(at: Self.modelFile)
                do {
                    try FileManager.default.moveItem(at: temporary, to: Self.modelFile)
                    outcome = .ready
                } catch {
                    outcome = .failed(error.localizedDescription)
                }
            } else {
                outcome = .failed(error?.localizedDescription ?? "download failed")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.download = nil
                self.state = outcome
                if outcome == .ready, self.enabled { self.load() }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let done = progress.fractionCompleted
            DispatchQueue.main.async { if case .downloading = self?.state { self?.state = .downloading(done) } }
        }
        download = task
        task.resume()
    }

    /// The model into memory, on the GPU — once.
    func load() {
        guard FileManager.default.fileExists(atPath: Self.modelFile.path) else {
            state = .absent
            return
        }
        if context != nil {
            state = .ready
            return
        }
        state = .loading
        queue.async { [self] in
            var parameters = whisper_context_default_params()
            parameters.use_gpu = true
            parameters.flash_attn = true
            let loaded = whisper_init_from_file_with_params(Self.modelFile.path, parameters)
            context = loaded
            DispatchQueue.main.async { self.state = loaded == nil ? .failed("the model didn't load") : .ready }
            loadANE()
        }
    }

    /// The Neural Engine's context, on the queue, if its encoder is here.
    nonisolated private func loadANE() {
        guard aneContext == nil, Self.hasEncoder else { return }
        if !FileManager.default.fileExists(atPath: Self.aneModel.path) {
            try? FileManager.default.linkItem(at: Self.modelFile, to: Self.aneModel)
        }
        let started = Date()
        var parameters = whisper_context_default_params()
        parameters.use_gpu = false
        aneContext = whisper_init_from_file_with_params(Self.aneModel.path, parameters)
        let seconds = Date().timeIntervalSince(started)
        let loaded = aneContext != nil
        Task { @MainActor in
            self.aneLoadSeconds = seconds
            let event: [String: Any] = ["e": "phone-whisper-ane-load", "t": Date().timeIntervalSince1970,
                                        "seconds": seconds, "loaded": loaded]
            _ = await Server.reachable()?.keyboardLog([event], batch: UUID().uuidString)
        }
    }

    enum Engine: String, CaseIterable {
        case gpu, ane, cpu
    }

    /// Hears a recording (the 16 kHz mono WAV the app records), as the Mac's bare listening does: the
    /// language found by itself, no prompt. `done` gets the text and the seconds it took.
    func hear(_ wav: URL, done: @escaping @MainActor (String, Double) -> Void) {
        guard state == .ready, context != nil, let samples = Self.samples(wav) else { return }
        queue.async { [self] in
            guard let context else { return }
            let started = Date()
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = 4
            parameters.no_timestamps = true
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            parameters.print_special = false
            parameters.temperature = 0
            let text: String = "auto".withCString { language in
                parameters.language = language
                guard whisper_full(context, parameters, samples, Int32(samples.count)) == 0 else { return "" }
                return (0..<whisper_full_n_segments(context))
                    .compactMap { whisper_full_get_segment_text(context, $0).map { String(cString: $0) } }
                    .joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                self.last = (text, seconds)
                done(text, seconds)
            }
        }
    }

    struct Listening {
        let segments: [String]
        /// Word pieces with how sure whisper was of each, as the Mac's server gives them.
        let pieces: [[String: Any]]
        let language: String?
        let seconds: Double
        let gpu: Bool
        let engine: Engine
    }

    /// One listening for the pipeline: blocks (call off the main thread). Nil when the model isn't
    /// here.
    /// `engine`: which one to hear on (a test); by default the GPU in front, else the Neural
    /// Engine if its encoder is here, else the CPU.
    nonisolated func listen(_ samples: [Float], language: String?, prompt: String?, engine wanted: Engine? = nil) -> Listening? {
        guard FileManager.default.fileExists(atPath: Self.modelFile.path) else { return nil }
        return queue.sync { () -> Listening? in
            var engine = wanted ?? (inFront && context != nil ? .gpu : Self.hasEncoder ? .ane : .cpu)
            if engine == .ane {
                loadANE()
                if aneContext == nil { engine = .cpu }
            }
            if engine == .gpu, context == nil { engine = .cpu }
            if engine == .cpu, cpuContext == nil {
                var parameters = whisper_context_default_params()
                parameters.use_gpu = false
                cpuContext = whisper_init_from_file_with_params(Self.modelFile.path, parameters)
            }
            let gpu = engine == .gpu
            guard let ctx = [.gpu: context, .ane: aneContext, .cpu: cpuContext][engine] ?? nil else { return nil }
            let started = Date()
            var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
            parameters.n_threads = gpu ? 4 : 6
            parameters.no_timestamps = true
            parameters.print_progress = false
            parameters.print_realtime = false
            parameters.print_timestamps = false
            parameters.print_special = false
            parameters.temperature = 0
            let ok: Bool = (language ?? "auto").withCString { lang in
                (prompt ?? "").withCString { initial in
                    parameters.language = lang
                    if let prompt, !prompt.isEmpty { parameters.initial_prompt = initial }
                    return whisper_full(ctx, parameters, samples, Int32(samples.count)) == 0
                }
            }
            guard ok else { return nil }
            var segments: [String] = []
            var pieces: [[String: Any]] = []
            let end = whisper_token_eot(ctx)
            for segment in 0..<whisper_full_n_segments(ctx) {
                segments.append(whisper_full_get_segment_text(ctx, segment).map { String(cString: $0) } ?? "")
                for token in 0..<whisper_full_n_tokens(ctx, segment) {
                    let data = whisper_full_get_token_data(ctx, segment, token)
                    guard data.id < end, let text = whisper_full_get_token_text(ctx, segment, token) else { continue }
                    pieces.append(["word": String(cString: text), "probability": Double(data.p)])
                }
            }
            let detected = whisper_full_lang_id(ctx)
            let detectedName = detected >= 0 ? whisper_lang_str(detected).map { String(cString: $0) } : nil
            return Listening(segments: segments, pieces: pieces, language: detectedName,
                             seconds: Date().timeIntervalSince(started), gpu: gpu, engine: engine)
        }
    }

    /// The recording's samples as whisper takes them: 32-bit floats at 16 kHz.
    nonisolated static func samples(_ wav: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

/// The engines side by side on one recording — the newest dictation kept on the phone — in front
/// (GPU, Neural Engine, CPU) or, after the app goes to the background, as the Action Button
/// would hear it there (Neural Engine, CPU). The times shown and sent to the Mac's log.
@MainActor
final class EngineBench: ObservableObject {
    static let shared = EngineBench()

    @Published private(set) var lines: [String] = []
    @Published private(set) var running = false

    static var newestRecording: URL? {
        let root = URL.documentsDirectory.appendingPathComponent("dictation")
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map { $0.appendingPathComponent("recording.wav") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func run(inBackground: Bool) {
        guard !running, let wav = Self.newestRecording, let samples = PhoneWhisper.samples(wav) else {
            lines = ["no recording kept on the phone yet"]
            return
        }
        running = true
        lines = []
        let audio = Double(samples.count) / 16_000
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task.detached {
            if inBackground {
                // Time to leave the app.
                await MainActor.run { self.lines = ["go to the home screen now…"] }
                try? await Task.sleep(for: .seconds(4))
                await MainActor.run { self.lines = [] }
            }
            let engines: [PhoneWhisper.Engine] = inBackground ? [.ane, .cpu] : [.gpu, .ane, .cpu]
            var events: [[String: Any]] = []
            for engine in engines {
                let front = await MainActor.run { UIApplication.shared.applicationState == .active }
                let heard = PhoneWhisper.shared.listen(samples, language: nil, prompt: nil, engine: engine)
                let line = heard.map { String(format: "%@ %.2f s (%@): %@", $0.engine.rawValue, $0.seconds, front ? "front" : "back",
                                              $0.segments.joined().trimmingCharacters(in: .whitespaces)) } ?? "\(engine.rawValue): failed"
                await MainActor.run { self.lines.append(line) }
                events.append(["e": "phone-whisper-bench", "t": Date().timeIntervalSince1970, "engine": heard?.engine.rawValue ?? engine.rawValue,
                               "wanted": engine.rawValue, "front": front, "seconds": heard?.seconds ?? -1, "audio_seconds": audio,
                               "text": heard?.segments.joined() ?? "", "recording": wav.deletingLastPathComponent().lastPathComponent])
            }
            _ = await Server.reachable()?.keyboardLog(events, batch: UUID().uuidString)
            await MainActor.run {
                self.running = false
                UIApplication.shared.endBackgroundTask(task)
            }
        }
    }
}
