import AVFoundation

/// Records the default microphone to a file, in whatever format the device delivers — whisper's
/// 16 kHz mono is made afterwards by ffmpeg, which is better at resampling than we'd be.
///
/// A fresh engine per recording: the input device (and its format) can change between holds, and
/// an engine that outlived its device delivers silence.
final class AudioRecorder {
    enum Permission {
        case granted
        case asked      // the system prompt is up; this hold can't record
        case denied
    }

    private var engine: AVAudioEngine?
    private var startedAt: Date?

    static func checkPermission() -> Permission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log.info("dictation: microphone access \(granted ? "granted" : "refused", privacy: .public)")
            }
            return .asked
        default:
            return .denied
        }
    }

    func start(to url: URL) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw Subprocess.Failure(description: "no microphone input (format \(format))")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            do { try file.write(from: buffer) } catch { log.error("dictation: audio write failed: \(error.localizedDescription, privacy: .public)") }
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        startedAt = Date()
    }

    /// Stops and closes the file (the tap held the last reference to it). Returns how long it ran.
    @discardableResult
    func stop() -> TimeInterval {
        guard let engine else { return 0 }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        defer { startedAt = nil }
        return startedAt.map { Date().timeIntervalSince($0) } ?? 0
    }
}
