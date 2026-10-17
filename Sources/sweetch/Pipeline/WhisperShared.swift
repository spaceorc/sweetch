import Foundation

/// What a listening of whisper gives the dictation pipeline, wherever whisper runs — a server on
/// the Mac (Whisper.swift), in-process on the iPhone — and the clean-up of what it heard, the same
/// on both.
enum Whisper {
    struct Word {
        let text: String
        let probability: Double
    }

    struct Heard {
        let text: String
        /// The language it was heard in: the one detected, or the one it was told.
        let language: String?
        /// Detection's probability for each language, when it detected.
        let languageProbabilities: [String: Double]
        let words: [Word]
        let json: URL
    }

    /// Short silences make whisper "hear" the closing lines of the subtitled videos it was trained
    /// on. When that's all a recording produced, nothing was said.
    static let phantomPhrases: Set<String> = [
        "продолжение следует", "субтитры сделал dimatorzok", "субтитры создавал dimatorzok",
        "редактор субтитров асемкин корректор аегорова", "спасибо за просмотр",
        "thank you", "thanks for watching", "you",
    ]

    /// The server's "words" are word pieces: a piece that starts with a space opens a word, the rest
    /// continue it. A word is as certain as its least certain piece. Punctuation is part of the text,
    /// not of the word, so it is trimmed from what is reported and does not count towards the
    /// probability.
    static func words(fromPieces pieces: [[String: Any]]) -> [Word] {
        var grouped: [[(String, Double)]] = []
        for token in pieces {
            guard let piece = token["word"] as? String, !piece.isEmpty, !piece.hasPrefix("[_") else { continue }
            if piece.hasPrefix(" ") || grouped.isEmpty { grouped.append([]) }
            grouped[grouped.count - 1].append((piece, token["probability"] as? Double ?? 1))
        }
        return grouped.compactMap { word in
            let text = word.map(\.0).joined()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:\"'()«»…"))
            let scored = word.filter { $0.0.contains { $0.isLetter || $0.isNumber } }.map(\.1)
            guard !text.isEmpty, let least = scored.min() else { return nil }
            return Word(text: text, probability: least)
        }
    }

    /// Whisper sometimes hears a phrase, then hears it all over again. Segments that repeat the ones
    /// before them, in full, go.
    static func withoutRepeat(_ segments: [String]) -> [String] {
        let n = segments.count
        guard n >= 2, n % 2 == 0 else { return segments }
        let half = n / 2
        let norm = { (s: [String]) in s.joined().lowercased().filter { $0.isLetter || $0.isNumber } }
        return norm(Array(segments[..<half])) == norm(Array(segments[half...])) ? Array(segments[..<half]) : segments
    }

    static func isPhantom(_ text: String) -> Bool {
        let bare = text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty || phantomPhrases.contains(bare)
    }

}
