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
        }
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
    }

    /// One listening for the pipeline: blocks (call off the main thread). Nil when the model isn't
    /// here.
    nonisolated func listen(_ samples: [Float], language: String?, prompt: String?) -> Listening? {
        guard FileManager.default.fileExists(atPath: Self.modelFile.path) else { return nil }
        return queue.sync { () -> Listening? in
            let gpu = inFront && context != nil
            if !gpu, cpuContext == nil {
                var parameters = whisper_context_default_params()
                parameters.use_gpu = false
                cpuContext = whisper_init_from_file_with_params(Self.modelFile.path, parameters)
            }
            guard let ctx = gpu ? context : cpuContext else { return nil }
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
                             seconds: Date().timeIntervalSince(started), gpu: gpu)
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
