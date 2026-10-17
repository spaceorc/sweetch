import AVFoundation
import Foundation
import whisper

/// Whisper on the phone itself — the Mac's engine (whisper.cpp, the same large-v3-turbo model),
/// on the phone's GPU. An experiment: a dictation made in the open app is heard here as well as on
/// the Mac, to see how fast and how well. (iOS gives an app in the background no GPU, so not yet for
/// the Action Button.)
@MainActor
final class PhoneWhisper: ObservableObject {
    static let shared = PhoneWhisper()

    static let modelURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin")!
    static var modelFile: URL { URL.documentsDirectory.appendingPathComponent("ggml-large-v3-turbo-q8_0.bin") }

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
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    private init() {
        if enabled { load() }
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

    /// The recording's samples as whisper takes them: 32-bit floats at 16 kHz.
    nonisolated private static func samples(_ wav: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
