import Foundation

/// One recording listened to several ways, the way Gemma's voice messages are, and settled into the
/// text the user said.
///
/// No single listening is trusted. Detection reads the sound alone and takes accented English for
/// Russian; told one language, whisper *translates* speech in the other; the prefix makes names
/// and terms come out right, but also leaks into what's heard. So, one after another on the
/// resident server:
/// - **auto, no prefix** — what the recording alone sounds like. It starts the moment the key is
///   released, without waiting for the prefix, and its language probabilities pick the likelier of
///   Russian and English: the user speaks those two and nothing else;
/// - **the likelier language, with the prefix**;
/// - **the other language, with the prefix** — for accented English detected as Russian, and the
///   reverse.
///
/// Listenings whose texts differ only in case and punctuation heard the same words and make one
/// version. Then a model settles what the user said, reading all of the context again, the prefix,
/// and every version with how it was heard and which of its words whisper was unsure of. It is
/// skipped only when every listening heard the same words and was sure of each one.
enum Hearing {
    enum Kind {
        case auto
        case likelier(String)
        case other(String)

        var language: String? {
            switch self {
            case .auto: return nil
            case .likelier(let l), .other(let l): return l
            }
        }

        var described: String {
            switch self {
            case .auto: return "auto-detected"
            case .likelier(let l): return "\(l) (the likelier language)"
            case .other(let l): return "\(l) (the other language)"
            }
        }
    }

    struct Listened {
        let kind: Kind
        let prompt: String?
        var prefixed: Bool { prompt != nil }
        let heard: Whisper.Heard
        let seconds: TimeInterval

        var record: [String: Any] {
            [
                "kind": kind.described, "prefixed": prefixed, "prompt": prompt ?? NSNull(), "language": heard.language ?? NSNull(),
                "text": heard.text, "json": heard.json.lastPathComponent, "seconds": seconds,
                "uncertain": Hearing.uncertain(heard.words).map { ["word": $0.text, "p": $0.probability] },
                "language_probabilities": Dictionary(uniqueKeysWithValues:
                    heard.languageProbabilities.sorted { $0.value > $1.value }.prefix(3).map { ($0.key, $0.value) }),
            ]
        }
    }

    struct Version {
        let text: String
        let members: [Listened]

        /// Whether every listening that produced it was primed: a word only such versions have may
        /// be the prefix speaking, not the user.
        var onlyPrefixed: Bool { members.allSatisfy(\.prefixed) }
        /// Whether only the listening told the less likely language produced it: it may be a
        /// translation.
        var onlyOtherLanguage: Bool { members.allSatisfy { if case .other = $0.kind { true } else { false } } }
        var language: String? { members.first?.heard.language }
        var uncertain: [Whisper.Word] { Hearing.uncertain(members[0].heard.words) }
    }

    struct Settled {
        let text: String
        let versions: [Version]
        /// What the model was asked and said, when it was asked.
        let settlement: [String: Any]?
    }

    /// Below this a word is reported as possibly misheard. Gemma's value, calibrated on English;
    /// Russian is still to be calibrated on the recordings.
    static let uncertainProbability = 0.7

    /// Blocks: whisper runs, and the model when it's needed. `prepared` blocks until the prefix and
    /// the context are in (or given up on). Throws only when no listening ran.
    static func hear(_ wav: URL, dir: URL,
                     prepared: () -> (prefix: Prefix?, context: ContextSnapshot.Gathered?)) throws -> Settled? {
        var listened: [Listened] = []
        var failures: [String] = []
        func listen(_ kind: Kind, prefix: String?, name: String) {
            let started = Date()
            do {
                let heard = try Whisper.hear(wav, language: kind.language, prompt: prefix, outputBase: dir.appendingPathComponent(name))
                listened.append(Listened(kind: kind, prompt: prefix, heard: heard, seconds: Date().timeIntervalSince(started)))
            } catch {
                failures.append("\(name): \(error)")
            }
        }

        listen(.auto, prefix: nil, name: "listen-auto")
        let p = listened.first?.heard.languageProbabilities ?? [:]
        let likelier = (p["en"] ?? 0) > (p["ru"] ?? 0) ? "en" : "ru"
        let other = likelier == "ru" ? "en" : "ru"
        let (prefix, context) = prepared()
        // Each language its own prefix: a prompt pulls whisper towards the language it's written in.
        if let prefix, prefix.text(for: likelier) != nil || prefix.text(for: other) != nil {
            listen(.likelier(likelier), prefix: prefix.text(for: likelier), name: "listen-\(likelier)-prefix")
            listen(.other(other), prefix: prefix.text(for: other), name: "listen-\(other)-prefix")
        } else {
            listen(.other(other), prefix: nil, name: "listen-\(other)")
        }
        if !failures.isEmpty { log.error("dictation: listenings failed: \(failures, privacy: .public)") }
        if listened.isEmpty { throw Subprocess.Failure(description: failures.joined(separator: "; ")) }

        let versions = grouped(listened.filter { !$0.heard.text.isEmpty })
        guard let first = versions.first else { return nil }
        if versions.count == 1, first.members.allSatisfy({ Hearing.uncertain($0.heard.words).isEmpty }) {
            return Settled(text: first.text, versions: versions, settlement: ["skipped": "every listening heard the same, surely"])
        }
        let prompts = Dictionary(listened.compactMap { l in l.prompt.map { (l.heard.language ?? "?", $0) } }) { a, _ in a }
        var (text, settlement) = settle(versions, prompts: prompts, context: context)
        // Noise makes whisper hear nothing, or a phantom we already drop. Speech that two listenings
        // made words of was said — even in two spellings ("Setup Tools" / "Ситап Тулс") — and the
        // model doesn't get to drop it.
        if text?.isEmpty == true, versions.reduce(0, { $0 + $1.members.count }) >= 2 {
            log.info("dictation: the model dropped what the listenings heard — typing the first version")
            settlement["overruled"] = "listenings heard words; an empty answer isn't accepted"
            text = nil
        }
        return Settled(text: text ?? first.text, versions: versions, settlement: settlement)
    }

    /// Most listenings first; among equals, the one whisper was surest of.
    private static func grouped(_ listened: [Listened]) -> [Version] {
        var groups: [String: [Listened]] = [:]
        var order: [String] = []
        for one in listened {
            let key = wordsOf(one.heard.text)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(one)
        }
        return order.map { groups[$0]! }
            .sorted { ($0.count, sureness($0[0])) > ($1.count, sureness($1[0])) }
            .map { Version(text: $0[0].heard.text, members: $0) }
    }

    private static func wordsOf(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func sureness(_ one: Listened) -> Double {
        let p = one.heard.words.map(\.probability)
        return p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count)
    }

    static func uncertain(_ words: [Whisper.Word]) -> [Whisper.Word] {
        words.filter { $0.probability < uncertainProbability }
    }

    // MARK: - Settling

    private static let system = """
    You work out what a user said into the microphone. They held a key in some app, dictated, and \
    released; whatever you answer is typed at their cursor as if they had typed it themselves. Getting \
    a word wrong there — a name, a term, a number — costs them more than a slightly awkward phrase.

    The user speaks only Russian and English: mostly Russian, often with English names and technical \
    terms inside it, which they write in Latin script ("закинул PR в anna-voice-messages"). Sometimes \
    a whole phrase in English.

    You get:
    - <context>: where they are speaking — the app, the window, who they are, words they use, the \
      texts the window shows (through Accessibility and/or read off a screenshot; noisy, partial, may \
      include unrelated panes), and what the field already holds before the cursor.
    - <prefix>: text the recogniser was primed with, as if the user had said it just before — one per \
      language, each priming the listenings in that language. Written from the same context, to make \
      names and terms come out right.
    - <versions>: every distinct text the recogniser produced from the recording, each with how it \
      was listened to, the language detected, and the words it was unsure of with their probability \
      (1.0 = certain; below ~0.7 = possibly misheard). Versions are ordered by how many listenings \
      produced them.

    How the recogniser goes wrong, and what each looks like:
    1. A TOLD LANGUAGE TRANSLATES. Listenings told a language — "the likelier language", picked \
       from detection, and "the other language" — write speech in another language as a translation. \
       A version in a language the speech wasn't in is never what was said; it only tells you the \
       meaning. Versions marked only_other_language are the usual suspects.
    2. DETECTION MISTAKES ACCENTED ENGLISH FOR RUSSIAN. Short English said with a Russian accent \
       comes out in Cyrillic or half-transliterated ("Тест-questions", "пул реквест"). If an English \
       version reads as plain natural English for the same sounds, they spoke English; if the speech \
       was Russian with an English term, keep the Russian and write the term in Latin. The language \
       of the screen is no evidence either way: they dictate Russian into English contexts and back.
    3. THE PREFIX LEAKS. A word found only in versions marked only_prefixed, and present in the \
       prefix, may be the prefix talking. Trust it when an unprefixed version has a similar-sounding \
       word in that place; distrust it when the unprefixed versions have nothing like it there.
    4. SIMILAR SOUNDS. The recogniser picks a common word over an unusual name or term that sounds \
       alike ("Best questions" for "test questions", "Pale" for "Pay"), and every listening can agree \
       on the same mistake. When a heard word — especially an uncertain one — sounds like a name or \
       term the context shows and the context makes that reading the sensible one, write the name or \
       term, spelt as the context spells it.
    5. TIDYING. The recogniser smooths over self-corrections and hesitations. A self-correction \
       ("1300, нет, 1500") — keep what they settled on, as they said it.

    Deciding:
    - Start from the versions, not the context. The context tells you what they are LIKELY to say, \
      not what they said; replace a heard word with a context word only under rule 4 — it sounds \
      alike and fits — never because the context mentions something.
    - Use only content some version contains: you may combine versions word by word and take a \
      term's spelling from the context, but never add or drop meaning, never answer, never translate.
    - It continues the text already in the field: if that ends mid-sentence, continue it (lowercase \
      start); match its style of punctuation — a chat message with no full stops gets none at the end.
    - Answer an empty text only when the versions are plainly noise — recogniser phantoms that \
      disagree with each other. Words the versions agree on were said, even if they make little \
      sense to you or the context doesn't explain them: type them.

    Reply with ONE JSON object and nothing else:
    {"reasoning": "<at most 15 words: which rule decided, if any>", "text": "<what the user said>"}
    """

    private static func settle(_ versions: [Version], prompts: [String: String], context: ContextSnapshot.Gathered?) -> (String?, [String: Any]) {
        var block = ""
        if let context { block += "<context>\n\(context.described(screenLimit: 12_000))\n</context>\n\n" }
        for (language, prompt) in prompts.sorted(by: { $0.key < $1.key }) {
            block += "<prefix language=\"\(language)\">\(prompt)</prefix>\n"
        }
        if !prompts.isEmpty { block += "\n" }
        block += "<versions>\n"
        for (i, v) in versions.enumerated() {
            let how = v.members.map { "\($0.kind.described)\($0.prefixed ? " + prefix" : "")" }
            var attributes = "n=\"\(i + 1)\" listenings=\"\(how.joined(separator: "; "))\""
            if let language = v.language { attributes += " language=\"\(language)\"" }
            if v.onlyPrefixed { attributes += " only_prefixed=\"yes\"" }
            if v.onlyOtherLanguage { attributes += " only_other_language=\"yes\"" }
            block += "<version \(attributes)>\n\(v.text)\n"
            let unsure = v.uncertain.map { "\($0.text) (\(String(format: "%.2f", $0.probability)))" }
            if !unsure.isEmpty { block += "<uncertain>\(unsure.joined(separator: ", "))</uncertain>\n" }
            block += "</version>\n"
        }
        block += "</versions>"

        var settlement: [String: Any] = ["input": block]
        guard LLMClient.isConfigured else { return (nil, settlement) }
        let started = Date()
        let done = DispatchSemaphore(value: 0)
        var raw: String?
        Task {
            defer { done.signal() }
            do {
                raw = try await LLMClient.complete(system: system, messages: [["role": "user", "content": block]], maxTokens: 600)
            } catch {
                log.error("dictation: settling failed: \(String(describing: error), privacy: .public)")
            }
        }
        done.wait()
        settlement["seconds"] = Date().timeIntervalSince(started)
        settlement["reply"] = raw ?? NSNull()
        guard let raw, let text = LLMJSON.string(raw, key: "text") else { return (nil, settlement) }
        // Content the versions don't have is the model talking, not the user.
        let longest = versions.map(\.text.count).max() ?? 0
        guard text.count <= longest * 3 / 2 + 20 else {
            log.error("dictation: settled text implausibly long, keeping the first version")
            return (nil, settlement)
        }
        if let reasoning = LLMJSON.string(raw, key: "reasoning") {
            log.info("dictation: settled — \(reasoning, privacy: .public)")
        }
        return (text, settlement)
    }
}
