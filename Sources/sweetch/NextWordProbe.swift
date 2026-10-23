import Foundation

/// `sweetch --next-word-probe <cases.json> <out.json>`: how well the model guesses the next word the
/// user typed, given the text before it — the cases are {before, truth}; the answer per case is
/// the model's three guesses. For deciding whether a model belongs in the keyboard's suggestions.
enum NextWordProbe {
    private static let system = """
    You predict the next word a person will type on a phone keyboard. They write mostly Russian, \
    with English technical terms, to an AI coding agent and to colleagues. Given the text so far, \
    reply with ONE JSON object: {"words": ["…", "…", "…"]} — the three likeliest next words, \
    likeliest first, lowercase, each a single word as it would be typed (inflected to fit).
    """

    /// `SWEETCH_PROBE_WIDE=1`: thirty words, for filtering by the letters typed as they come.
    private static let wide = """
    You predict the next word a person will type on a phone keyboard. They write mostly Russian, \
    with English technical terms, to an AI coding agent and to colleagues. Given the text so far, \
    reply with ONE JSON object: {"words": [...]} — the 30 likeliest next words, likeliest first, \
    lowercase, each a single word as it would be typed (inflected to fit), all different.
    """

    static func run(_ input: URL, _ output: URL) {
        let isWide = ProcessInfo.processInfo.environment["SWEETCH_PROBE_WIDE"] != nil
        guard let data = try? Data(contentsOf: input),
              let cases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: String]] else {
            print("no cases in \(input.path)")
            return
        }
        let done = DispatchSemaphore(value: 0)
        Task {
            var results: [[String: Any]] = []
            for (i, c) in cases.enumerated() {
                let started = Date()
                var words: [String] = []
                do {
                    let reply = try await LLMClient.complete(system: isWide ? wide : system,
                                                             messages: [["role": "user", "content": "Text so far: «\(c["before"] ?? "")»"
                                                                + (c["prefix"].map { "\nThe next word starts with «\($0)»." } ?? "")]],
                                                             maxTokens: isWide ? 400 : 60, purpose: "probe")
                    words = (LLMJSON.object(reply)?["words"] as? [String] ?? []).map { $0.lowercased() }
                } catch {
                    print("case \(i): \(error)")
                }
                results.append(["truth": c["truth"] ?? "", "words": words, "seconds": Date().timeIntervalSince(started)])
                if i % 10 == 9 { print("\(i + 1)/\(cases.count)") }
            }
            try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]).write(to: output)
            done.signal()
        }
        done.wait()
    }
}
