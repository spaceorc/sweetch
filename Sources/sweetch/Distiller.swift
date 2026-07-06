import Foundation

/// Periodically distills the correction/revert history into glossary terms using a smarter
/// model (Sonnet) than the per-keystroke corrector (Haiku). Run on demand from the menu.
enum Distiller {
    private static let model = "claude-sonnet-4-5-20250929"   // deployed on our Foundry
    private static let system = """
    You analyze a user's text-correction history from a Punto-Switcher-style tool. Each line is a \
    JSON event with kind "correct" (the tool changed the user's text) or "revert" (the user UNDID a \
    correction, i.e. they preferred their own original wording).

    Find words the user DELIBERATELY uses that the corrector should keep as-is and NOT normalize to \
    standard synonyms — professional/dev slang, borrowed tech terms, product names, personal shorthand. \
    Strong signal: words that appear in the "original" of revert events. Ignore genuine typos, \
    wrong-layout gibberish, and one-off noise. Do not include ordinary correctly-spelled common words.

    Reply with ONE JSON object and nothing else: {"words": ["word1", "word2", ...]} — words as the \
    user writes them. If nothing qualifies, return {"words": []}.
    """

    /// Returns the number of new words added to the glossary.
    static func run() async -> Int {
        let history = History.recentJSONL()
        guard !history.isEmpty else { log.info("distill: no history yet"); return 0 }
        do {
            let raw = try await LLMClient.complete(
                system: system,
                messages: [["role": "user", "content": "History (JSONL):\n" + history]],
                maxTokens: 1024,
                model: model
            )
            guard let words = parseWords(raw), !words.isEmpty else {
                log.info("distill: nothing to add")
                return 0
            }
            let before = Set(Glossary.terms().map { $0.lowercased() })
            Glossary.add(words)
            let added = words.filter { !before.contains($0.lowercased()) }
            log.info("distill: added \(added, privacy: .public)")
            return added.count
        } catch {
            log.error("distill failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    private static func parseWords(_ raw: String) -> [String]? {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let words = obj["words"] as? [String] else { return nil }
        return words.filter { $0.count >= 2 }
    }
}
