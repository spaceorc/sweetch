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
/// The spoken part is one sentence, once in Russian and once in English (a prompt pulls whisper
/// towards its own language): where the user is and the few names and terms they're likely to say,
/// which the fast model picks from what was gathered while they speak.
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
    private static let precedingLimit = 300
    private static let maxTerms = 4

    // The model only picks the words; the sentence is ours. Asked to write the sentence itself, it
    // transliterated names ("Denis Khranovskii" → "Денис Храновский") and kept naming the speaker,
    // however the prompt put it — and a prefix exists to spell names the way the screen does.
    private static let system = """
    The user speaks Russian and English and is about to dictate into the app and window described \
    below. From the context, pick the two to four people, product names, project names or technical \
    terms they are most likely to say next — the ones in the conversation or document they are \
    working on, not menus, buttons or unrelated panes.

    Copy each EXACTLY as the context writes it, character for character: no translating, \
    transliterating, declining or capitalising differently. The speaker is USER_NAME — never pick \
    them. Fewer is better than unsure.

    Reply with ONE JSON object and nothing else: {"terms": ["...", "..."]}
    """

    /// Blocks on the network — call off the main thread. Never throws: without the model there is
    /// still the field's text.
    static func build(from context: ContextSnapshot.Gathered) -> Prefix {
        // Only prose is what the speech continues; code before the cursor would make whisper hear code.
        let preceding = context.textBeforeCursor.map(tail).flatMap { isProse($0) ? $0 : nil }
        guard LLMClient.isConfigured else { return Prefix(spoken: [:], preceding: preceding) }
        let screen = ([context.windowTitle ?? "", context.ocrText ?? "", context.textBeforeCursor ?? ""] + context.windowTexts)
            .joined(separator: "\n")
        let terms = pickTerms(context.described(screenLimit: 2000, fieldLimit: 600))
            .filter { screen.contains($0) && !isSpeaker($0) }
            .prefix(maxTerms)
        return Prefix(spoken: sentences(app: context.app, terms: Array(terms)), preceding: preceding)
    }

    /// The scene in the user's voice, once per language, with the terms as the screen spells them.
    private static func sentences(app: String, terms: [String]) -> [String: String] {
        func listed(_ items: [String], and: String) -> String {
            items.count == 1 ? items[0] : items.dropLast().joined(separator: ", ") + " \(and) " + items[items.count - 1]
        }
        guard !terms.isEmpty else { return ["ru": "Я сейчас в \(app).", "en": "I'm in \(app) now."] }
        return ["ru": "Я сейчас в \(app), речь про \(listed(terms, and: "и")).",
                "en": "I'm in \(app) now, talking about \(listed(terms, and: "and"))."]
    }

    private static func pickTerms(_ context: String) -> [String] {
        let done = DispatchSemaphore(value: 0)
        var terms: [String] = []
        Task {
            defer { done.signal() }
            do {
                let system = system.replacingOccurrences(of: "USER_NAME", with: NSFullUserName())
                let raw = try await LLMClient.complete(system: system, messages: [["role": "user", "content": context]],
                                                       maxTokens: 200)
                terms = (LLMJSON.object(raw)?["terms"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            } catch {
                log.error("dictation: prefix failed: \(String(describing: error), privacy: .public)")
            }
        }
        done.wait()
        return terms
    }

    /// Whether a term is the speaker: their first name as a word in it, in Latin or Cyrillic letters
    /// and any case ending. Someone who only shares the surname isn't.
    private static func isSpeaker(_ term: String) -> Bool {
        guard let first = NSFullUserName().split(separator: " ").first.map(String.init), first.count >= 2 else { return false }
        return [first, cyrillic(first)].contains { name in
            let stem = NSRegularExpression.escapedPattern(for: String(name.prefix(max(3, name.count - 1))))
            return term.range(of: "\\b\(stem)\\w*\\b", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A Latin-spelt Russian name back in Cyrillic: "Dashkevich" → "Дашкевич". ICU's transform reads
    /// "sh" and "ch" as two letters each.
    private static func cyrillic(_ latin: String) -> String {
        let digraphs = [("shch", "щ"), ("sh", "ш"), ("ch", "ч"), ("kh", "х"), ("zh", "ж"), ("ts", "ц"),
                        ("ya", "я"), ("yu", "ю"), ("yo", "ё"), ("ye", "е")]
        let letters: [Character: String] = ["a": "а", "b": "б", "v": "в", "g": "г", "d": "д", "e": "е", "z": "з",
                                            "i": "и", "y": "й", "k": "к", "l": "л", "m": "м", "n": "н", "o": "о",
                                            "p": "п", "r": "р", "s": "с", "t": "т", "u": "у", "f": "ф", "h": "х",
                                            "c": "к", "x": "кс", "w": "в", "j": "дж", "q": "к"]
        var rest = Substring(latin.lowercased())
        var out = ""
        while let first = rest.first {
            if let (from, to) = digraphs.first(where: { rest.hasPrefix($0.0) }) {
                out += to
                rest = rest.dropFirst(from.count)
            } else {
                out += letters[first] ?? String(first)
                rest = rest.dropFirst()
            }
        }
        return out
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
