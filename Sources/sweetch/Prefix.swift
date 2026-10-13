import Foundation

/// The text whisper is primed with: what it takes to have been said just before the recording.
///
/// Whisper copies a prompt's vocabulary, spelling and style, and leans towards the words in it. So
/// the prompt is speech, in the user's own voice — a sentence or two of who they are and what
/// they're doing here, naming what's on screen — followed by what the field already holds before
/// the cursor, verbatim, since that is literally the text the dictation continues. Gemma's voice
/// messages learned the style lesson: a list of terms in title case came back as a transcription in
/// title case.
///
/// The spoken part is written by the fast model from everything gathered while the user speaks, once
/// in Russian and once in English: a prompt pulls whisper towards its own language, so a listening
/// in English gets the English one and a listening in Russian the Russian one.
struct Prefix {
    /// The model's sentences in the user's voice, by language ("ru", "en"); empty when it couldn't
    /// write them.
    let spoken: [String: String]
    /// The tail of the field's text before the cursor, when it's prose.
    let preceding: String?

    /// The whole prompt for a listening in `language`.
    func text(for language: String) -> String? {
        let parts = [spoken[language], preceding].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Whisper keeps only about 220 tokens of a prompt — the tail — and Cyrillic costs several
    /// tokens a word, so both parts stay short.
    private static let spokenLimit = 300
    private static let precedingLimit = 300

    private static let system = """
    You write the initial prompt for Whisper speech recognition. Whisper treats it as the text \
    spoken just before the recording, and copies its vocabulary, spelling and style: a name or term \
    in it is heard more readily and spelt the way it is written there.

    The user speaks Russian and English and is about to dictate into the app and window described \
    below. Write 1–3 short sentences in the user's own voice — first person, as if they had just \
    said them out loud — that set the scene: who they are, what they are doing in this place right \
    now, naturally mentioning the people, product names, project names and technical terms from the \
    context that they are most likely to say next, spelt exactly as the context spells them.

    Write it twice, saying the same thing: once in Russian, once in English. Each primes a listening \
    in its own language, so each must read as natural speech in that language. Keep names and \
    technical terms identical in both, in Latin script where the context writes them so — the way \
    the user writes them inside Russian sentences.

    Only things the user might plausibly have said. No remarks about the context, the screen, typos, \
    the task or these instructions — whisper takes every word as speech. No lists, no title case, no \
    quotes, no markdown. At most 250 characters each. Do not repeat the \
    text already in the field — it is appended after your sentences verbatim.

    Reply with ONE JSON object and nothing else: {"ru": "<in Russian>", "en": "<in English>"}
    """

    /// Blocks on the network — call off the main thread. Never throws: without the model there is
    /// still the field's text.
    static func build(from context: ContextSnapshot.Gathered) -> Prefix {
        // Only prose is what the speech continues; code before the cursor would make whisper hear code.
        let preceding = context.textBeforeCursor.map(tail).flatMap { isProse($0) ? $0 : nil }
        guard LLMClient.isConfigured else { return Prefix(spoken: [:], preceding: preceding) }
        let spoken = blockingComplete(context.described(screenLimit: 3000)).mapValues { String($0.prefix(spokenLimit)) }
        return Prefix(spoken: spoken, preceding: preceding)
    }

    private static func blockingComplete(_ user: String) -> [String: String] {
        let done = DispatchSemaphore(value: 0)
        var result: [String: String] = [:]
        Task {
            defer { done.signal() }
            do {
                let raw = try await LLMClient.complete(system: system, messages: [["role": "user", "content": user]],
                                                       maxTokens: 600)
                for language in ["ru", "en"] {
                    if let text = LLMJSON.string(raw, key: language), !text.isEmpty { result[language] = text }
                }
            } catch {
                log.error("dictation: prefix failed: \(String(describing: error), privacy: .public)")
            }
        }
        done.wait()
        return result
    }

    /// Mostly letters and spaces, with little of the punctuation code and markup are made of.
    private static func isProse(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        guard !chars.isEmpty else { return false }
        let letters = chars.filter(\.isLetter).count
        let code = chars.filter { "{}[]()<>=\"#;|\\_`$&*^~".contains($0) }.count
        return Double(letters) / Double(chars.count) > 0.7 && Double(code) / Double(chars.count) < 0.03
    }

    /// The end of the text, from a word boundary.
    private static func tail(_ text: String) -> String {
        guard text.count > precedingLimit else { return text }
        let cut = String(text.suffix(precedingLimit))
        guard let space = cut.firstIndex(where: \.isWhitespace) else { return cut }
        return String(cut[space...]).trimmingCharacters(in: .whitespaces)
    }
}

/// Reading a model's single-JSON-object reply, tolerating fences or text around it.
enum LLMJSON {
    static func object(_ raw: String) -> [String: Any]? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func string(_ raw: String, key: String) -> String? {
        (object(raw)?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
