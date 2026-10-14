import AVFoundation
import Speech

/// The words as they are said, on Apple's on-device dictation model — for the Dynamic Island, and
/// as the phone's own version of what was said: the Mac weighs it with its listenings, and it is
/// what's typed when the Mac can't be reached. Russian, as on the Mac.
final class LivePreview: @unchecked Sendable {
    private static let locale = Locale(identifier: "ru_RU")

    private let transcriber = DictationTranscriber(locale: LivePreview.locale, preset: .progressiveShortDictation)
    private let analyzer: SpeechAnalyzer
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var latest = ""
    private let heardAll = DispatchSemaphore(value: 0)

    /// Fetches the model when it isn't on the phone yet.
    static func prepare() {
        Task {
            let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            guard await AssetInventory.status(forModules: [module]) != .installed else { return }
            try? await AssetInventory.assetInstallationRequest(supporting: [module])?.downloadAndInstall()
        }
    }

    /// `onText` gets the whole transcript so far.
    init(onText: @escaping @Sendable (String) -> Void) {
        analyzer = SpeechAnalyzer(modules: [transcriber])
        let (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.feed = feed
        let transcriber = transcriber
        Task { [weak self] in
            defer { self?.heardAll.signal() }
            var settled = AttributedString()
            do {
                for try await result in transcriber.results {
                    let text: AttributedString
                    if result.isFinal {
                        settled += result.text
                        text = settled
                    } else {
                        text = settled + result.text
                    }
                    let plain = String(text.characters)
                    self?.lock.withLock { self?.latest = plain }
                    onText(plain)
                }
            } catch {}
        }
        let analyzer = analyzer
        Task { [weak self] in
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                Self.prepare()
                return
            }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            self?.lock.withLock { self?.format = format }
            try? await analyzer.start(inputSequence: input)
        }
    }

    /// From the microphone's tap, on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        feed.yield(AnalyzerInput(buffer: converted))
    }

    func finish() {
        feed.finish()
        Task { [analyzer] in try? await analyzer.finalizeAndFinishThroughEndOfInput() }
    }

    /// The final transcript, waiting up to `seconds` for the model after `finish()`.
    func transcript(waiting seconds: TimeInterval) async -> String? {
        await withCheckedContinuation { done in
            DispatchQueue.global().async { [self] in
                _ = heardAll.wait(timeout: .now() + seconds)
                let text = lock.withLock { latest }.trimmingCharacters(in: .whitespacesAndNewlines)
                done.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard let format else { return nil }
            if buffer.format == format { return buffer }
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return nil }
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
}
