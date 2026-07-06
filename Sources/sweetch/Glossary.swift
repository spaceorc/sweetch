import Foundation

/// A personal glossary of words the user deliberately uses (e.g. "заапрувил", "смёржил")
/// that the model should keep as-is instead of "correcting" to standard synonyms.
///
/// Backed by a plain-text file (one word per line) so the user can view and edit it directly
/// from the menu. Populated two ways: a cheap repetition heuristic (undo the same word→change
/// twice), and periodic distillation of the full history by a smarter model (see Distiller).
enum Glossary {
    private static let pendingKey = "userGlossaryPending"   // word(lowercased) -> undo count
    private static let promoteThreshold = 2
    private static let maxTerms = 300

    static func terms() -> [String] {
        guard let s = try? String(contentsOf: AppSupport.glossary, encoding: .utf8) else { return [] }
        return s.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func add(_ words: [String]) {
        var list = terms()
        var seen = Set(list.map { $0.lowercased() })
        for w in words where !seen.contains(w.lowercased()) {
            list.append(w)
            seen.insert(w.lowercased())
        }
        if list.count > maxTerms { list = Array(list.suffix(maxTerms)) }
        write(list)
    }

    private static func write(_ list: [String]) {
        let header = "# sweetch glossary — one word per line. These are kept as-is by the corrector.\n"
        try? (header + list.joined(separator: "\n") + "\n").write(to: AppSupport.glossary, atomically: true, encoding: .utf8)
    }

    /// Fast heuristic: the user undid a correction. Words present in the original but gone from
    /// the correction get an undo tally; a word crossing the threshold is promoted. One-off
    /// undos (typos, disliked results) never reach the glossary.
    static func noteRevert(fromOriginal original: String, corrected: String) {
        let correctedWords = Set(tokenize(corrected).map { $0.lowercased() })
        let candidates = tokenize(original).filter { $0.count >= 3 && !correctedWords.contains($0.lowercased()) }
        guard !candidates.isEmpty else { return }

        var pending = UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Int] ?? [:]
        var known = Set(terms().map { $0.lowercased() })
        var promoted: [String] = []
        for word in candidates {
            let lw = word.lowercased()
            if known.contains(lw) { continue }
            let count = (pending[lw] ?? 0) + 1
            if count >= promoteThreshold {
                promoted.append(word); known.insert(lw); pending[lw] = nil
            } else {
                pending[lw] = count
                log.info("glossary: '\(word, privacy: .public)' undone \(count, privacy: .public)/\(promoteThreshold, privacy: .public)")
            }
        }
        UserDefaults.standard.set(pending, forKey: pendingKey)
        if !promoted.isEmpty { add(promoted); log.info("glossary: learned \(promoted, privacy: .public)") }
    }

    static func promptSection() -> String {
        let t = terms()
        guard !t.isEmpty else { return "" }
        return """


        USER GLOSSARY — words the user deliberately uses. Keep these EXACTLY as written; do NOT \
        translate, normalize, or replace them with synonyms (still fix genuine typos and wrong-layout \
        gibberish around them). Glossary: \(t.joined(separator: ", "))
        """
    }

    private static func tokenize(_ s: String) -> [String] {
        s.split { !$0.isLetter && $0 != "-" }.map(String.init)
    }
}
