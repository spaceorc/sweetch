import os
import UIKit
import Vision

// What the dictation pipeline (Sources/sweetch/Pipeline, shared with the Mac) needs from the
// platform it runs on — here, the iPhone.

let log = Logger(subsystem: "com.spaceorc.sweetch.phone", category: "pipeline")

enum Subprocess {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
}

extension Whisper {
    /// One listening, as the Mac's server gives it: whisper.cpp in the app, on the GPU while the app
    /// is in front, on the CPU behind (iOS gives an app in the background no GPU).
    static func hear(_ wav: URL, language: String?, prompt: String?, outputBase: URL) throws -> Heard {
        guard let samples = PhoneWhisper.samples(wav) else { throw Subprocess.Failure(description: "the recording didn't read") }
        guard let heard = PhoneWhisper.shared.listen(samples, language: language, prompt: prompt) else {
            throw Subprocess.Failure(description: "whisper isn't loaded on the phone")
        }
        let json = outputBase.appendingPathExtension("json")
        let record: [String: Any] = ["segments": heard.segments, "language": heard.language ?? NSNull(),
                                     "words": heard.pieces, "seconds": heard.seconds, "gpu": heard.gpu]
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted]).write(to: json)
        let text = withoutRepeat(heard.segments).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let phantom = isPhantom(text)
        // whisper.cpp tells the language it chose, not how sure it was: sure enough, as the pipeline
        // goes on to the other language only when the listenings disagree.
        var probabilities: [String: Double] = [:]
        if language == nil, let detected = heard.language {
            probabilities = [detected: 0.9, detected == "ru" ? "en" : "ru": 0.05]
        }
        return Heard(text: phantom ? "" : text, language: language ?? heard.language,
                     languageProbabilities: probabilities,
                     words: phantom ? [] : words(fromPieces: heard.pieces), json: json)
    }
}

extension ContextSnapshot {
    /// The text a screenshot shows, read as the Mac reads it.
    static func readText(in png: URL) -> String? {
        guard let image = UIImage(contentsOfFile: png.path)?.cgImage else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image).perform([request])
        } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? nil : String(lines.joined(separator: "\n").prefix(20_000))
    }
}
