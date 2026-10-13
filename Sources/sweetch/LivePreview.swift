import AVFoundation
import Speech

/// A rough transcript while the user is still speaking, for the overlay to show — the words as they
/// come, on Apple's on-device dictation model. It is only a preview: what gets typed is whisper's,
/// heard several ways and settled after release. Russian only, since that's what the user mostly
/// speaks; English terms come out mangled here and right in the end.
@available(macOS 26.0, *)
final class LivePreview: @unchecked Sendable {
    private static let locale = Locale(identifier: "ru_RU")

    private let transcriber = DictationTranscriber(locale: LivePreview.locale, preset: .progressiveShortDictation)
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>
    private let feed: AsyncStream<AnalyzerInput>.Continuation
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var format: AVAudioFormat?
    private var tasks: [Task<Void, Never>] = []

    /// Fetches the model for the next time when it isn't on the machine yet.
    static func prepare() {
        Task {
            let module = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            guard await AssetInventory.status(forModules: [module]) != .installed else { return }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    try await request.downloadAndInstall()
                    log.info("live preview: the Russian dictation model is installed")
                }
            } catch {
                log.error("live preview: model download failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `onText` gets the whole transcript so far, on the main thread.
    init(onText: @escaping (String) -> Void) {
        analyzer = SpeechAnalyzer(modules: [transcriber])
        (input, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let transcriber = transcriber
        tasks.append(Task {
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
                    DispatchQueue.main.async { onText(plain) }
                }
            } catch {
                log.error("live preview: \(error.localizedDescription, privacy: .public)")
            }
        })
        let analyzer = analyzer
        let input = input
        tasks.append(Task { [weak self] in
            do {
                guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                    log.info("live preview: no Russian model yet — fetching it for next time")
                    Self.prepare()
                    return
                }
                let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                self?.lock.withLock { self?.format = format }
                try await analyzer.start(inputSequence: input)
            } catch {
                log.error("live preview: couldn't start: \(error.localizedDescription, privacy: .public)")
            }
        })
    }

    /// From the microphone's tap, on the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        feed.yield(AnalyzerInput(buffer: converted))
    }

    func stop() {
        feed.finish()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        tasks.forEach { $0.cancel() }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        lock.withLock {
            guard let format else { return nil }   // not started yet: the first fraction of a second is lost
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
