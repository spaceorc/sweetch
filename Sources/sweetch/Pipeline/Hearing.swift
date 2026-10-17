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
/// - if Apple's live recogniser heard the same as that first listening and the other language is
///   unlikely, that's the answer — a plain Russian phrase, about 0.65 s after release;
/// - **the likelier language, with its prefix**. If it heard the same words as the first and the
///   other language was unlikely, that's the answer — about a second after release;
/// - otherwise **the other language, with its prefix** — for accented English detected as Russian,
///   and the reverse — and then the model.
///
/// Listenings whose texts differ only in case and punctuation heard the same words and make one
/// version. Then a model settles what the user said, reading all of the context again, the prefix,
/// and every version with how it was heard and which of its words whisper was unsure of. It is
/// skipped when every listening heard the same words.
enum Hearing {
    enum Kind {
        case auto
        case likelier(String)
        case other(String)
        /// Apple's on-device dictation model, which heard the user live for the preview: a second,
        /// independent recogniser, Russian only.
        case apple

        var language: String? {
            switch self {
            case .auto: return nil
            case .likelier(let l), .other(let l): return l
            case .apple: return "ru"
            }
        }

        var described: String {
            switch self {
            case .auto: return "auto-detected"
            case .likelier(let l): return "\(l) (the likelier language)"
            case .other(let l): return "\(l) (the other language)"
            case .apple: return "Apple dictation, ru (a different recogniser)"
            }
        }

        var isWhisper: Bool {
            if case .apple = self { false } else { true }
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

    /// Detection's probability for the other language at which it gets a listening even when the first
    /// two agree. Russian speech scored English 0.02–0.19 on the user's recordings, so this only spares
    /// the clear cases.
    static let otherLanguageDoubt = 0.1

    /// Below this a word is reported as possibly misheard. Gemma's value, calibrated on English;
    /// Russian is still to be calibrated on the recordings.
    static let uncertainProbability = 0.7

    /// Blocks: whisper runs, and the model when it's needed. `prepared` blocks until the prefix and
    /// the context are in (or given up on). Throws only when no listening ran.
    static func hear(_ wav: URL, dir: URL,
                     prepared: () -> (prefix: Prefix?, context: ContextSnapshot.Gathered?, apple: String?)) throws -> Settled? {
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
        let (prefix, context, apple) = prepared()

        // Apple's recogniser, which heard the user live, agreeing with whisper's bare listening: two
        // independent recognisers heard the same, in a language detection had little doubt about. The
        // prefixed listening would add nothing — where it matters, on English names and terms, Apple's
        // Russian model mangles them and doesn't agree.
        if let apple, let bare = listened.first, !bare.heard.text.isEmpty, (p[other] ?? 0) < otherLanguageDoubt {
            let appleHeard = Listened(kind: .apple, prompt: nil,
                                      heard: Whisper.Heard(text: apple, language: "ru", languageProbabilities: [:], words: [],
                                                           json: dir.appendingPathComponent("preview")),
                                      seconds: 0)
            let bareVersion = Version(text: bare.heard.text, members: [bare])
            if agrees(apple, with: bareVersion) {
                return Settled(text: inAppleScript(bare.heard.text, apple: apple),
                               versions: grouped([bare, appleHeard]),
                               settlement: ["skipped": "Apple's recogniser heard the same as the bare listening"])
            }
        }

        // Each language its own prefix: a prompt pulls whisper towards the language it's written in.
        let primed = prefix?.text(for: likelier)
        listen(.likelier(likelier), prefix: primed, name: primed == nil ? "listen-\(likelier)" : "listen-\(likelier)-prefix")

        // Heard alike with and without the prefix, in a language detection had little doubt about:
        // that is what was said, and the other language and the model would only cost time.
        let agreed = listened.count == 2 && !listened[0].heard.text.isEmpty
            && wordsOf(listened[0].heard.text) == wordsOf(listened[1].heard.text)
        let doubt = p[other] ?? 0
        if !agreed || doubt >= otherLanguageDoubt {
            let otherPrimed = prefix?.text(for: other)
            listen(.other(other), prefix: otherPrimed, name: otherPrimed == nil ? "listen-\(other)" : "listen-\(other)-prefix")
        }
        if !failures.isEmpty { log.error("dictation: listenings failed: \(failures, privacy: .public)") }
        if listened.isEmpty { throw Subprocess.Failure(description: failures.joined(separator: "; ")) }

        // Nothing heard without the prefix means nothing was said: a prefixed listening that hears
        // something in silence is the prefix talking ("Спасибо.").
        guard let bare = listened.first(where: { if case .auto = $0.kind { true } else { false } }),
              !bare.heard.text.isEmpty else { return nil }
        let whisperVersions = grouped(listened.filter { !$0.heard.text.isEmpty })
        guard let first = whisperVersions.first else { return nil }
        if let apple {
            listened.append(Listened(kind: .apple, prompt: nil,
                                     heard: Whisper.Heard(text: apple, language: "ru", languageProbabilities: [:], words: [],
                                                          json: dir.appendingPathComponent("preview")),
                                     seconds: 0))
        }
        let versions = grouped(listened.filter { !$0.heard.text.isEmpty })

        // Apple's recogniser drops punctuation and endings, so it agrees with a version when its words
        // are that version's, loosely. The whisper versions it backs:
        let appleBacks = apple.map { a in whisperVersions.filter { agrees(a, with: $0) } }
        if whisperVersions.count == 1, appleBacks.map({ !$0.isEmpty }) ?? true {
            let why = listened.filter(\.kind.isWhisper).count == 2
                ? "heard alike with and without the prefix; \(other) unlikely (\(String(format: "%.2f", doubt)))"
                : "every listening heard the same"
            return Settled(text: inAppleScript(first.text, apple: apple), versions: versions, settlement: ["skipped": why])
        }
        // Whisper's listenings disagree and Apple's recogniser heard one of them: two recognisers
        // behind it settle it without the model.
        if whisperVersions.count > 1, let backs = appleBacks, backs.count == 1 {
            return Settled(text: inAppleScript(backs[0].text, apple: apple), versions: versions,
                           settlement: ["skipped": "Apple's recogniser heard the same as one of the versions"])
        }
        let prompts = Dictionary(listened.compactMap { l in l.prompt.map { (l.heard.language ?? "?", $0) } }) { a, _ in a }
        // Should the model's answer be refused, the version heard without the prefix stands: it is the
        // recording's own.
        let fallback = versions.first { $0.members.contains { if case .auto = $0.kind { true } else { false } } } ?? first
        var (text, settlement) = settle(versions, prompts: prompts, context: context)
        // What the versions don't back is the context talking, not the user.
        if let answer = text, !answer.isEmpty, !backed(answer, by: versions) {
            log.error("dictation: the model's answer isn't backed by what was heard — typing the bare version")
            settlement["overruled"] = "answer not backed by the versions: \(answer)"
            text = nil
        }
        // Noise makes whisper hear nothing, or a phantom we already drop. Speech that two listenings
        // made words of was said — even in two spellings ("Setup Tools" / "Ситап Тулс") — and the
        // model doesn't get to drop it.
        if text?.isEmpty == true, versions.reduce(0, { $0 + $1.members.count }) >= 2 {
            log.info("dictation: the model dropped what the listenings heard — typing the bare version")
            settlement["overruled"] = "listenings heard words; an empty answer isn't accepted"
            text = nil
        }
        return Settled(text: text ?? fallback.text, versions: versions, settlement: settlement)
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

    /// Whether an answer stays with what was heard: every number in it was heard as such, and most of
    /// its words have a counterpart in some version — the same word, in either script ("тест" is
    /// "test"), or one that shares its start ("setup tools" for "setuptools").
    static func backed(_ answer: String, by versions: [Version]) -> Bool {
        let heard = Set(versions.flatMap { latinWords($0.text) })
        let said = latinWords(answer)
        guard !said.isEmpty else { return true }
        let numbers = said.filter { $0.allSatisfy(\.isNumber) }
        guard numbers.allSatisfy(heard.contains) else { return false }
        let matched = said.filter { word in
            heard.contains { h in h == word || (min(h.count, word.count) >= 4 && (h.hasPrefix(word) || word.hasPrefix(h)
                || h.commonPrefix(with: word).count >= 4)) }
        }
        return Double(matched.count) >= Double(said.count) * 0.6
    }

    /// Apple's transcript agrees with a version when its words are the version's, loosely, and the
    /// version isn't much longer than what it heard (whisper sometimes hears a phrase twice).
    private static func agrees(_ apple: String, with version: Version) -> Bool {
        backed(apple, by: [version]) && Double(latinWords(version.text).count) <= Double(latinWords(apple).count) * 1.4 + 1
    }

    /// Whisper sometimes writes Russian in Latin letters ("Ura!"). When Apple's recogniser heard the
    /// same words in Cyrillic, its spelling is the Russian one; whisper's punctuation is kept.
    private static func inAppleScript(_ text: String, apple: String?) -> String {
        guard let apple else { return text }
        let latin = { (s: String) in s.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count }
        let cyrillic = { (s: String) in s.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count }
        guard latin(text) > cyrillic(text), cyrillic(apple) > latin(apple),
              latinWords(text) == latinWords(apple) else { return text }
        let tail = text.reversed().prefix { !$0.isLetter && !$0.isNumber }
        return apple + String(tail.reversed())
    }

    private static func latinWords(_ text: String) -> [String] {
        let latin = text.lowercased().applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? text.lowercased()
        return String(latin.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").map(String.init)
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

    private static let settleTimeout: TimeInterval = 1.5

    /// A reply that may land after the wait for it gave up.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    private static let system = """
    You work out what a user said into the microphone. They held a key in some app, dictated, and \
    released; whatever you answer is typed at their cursor as if they had typed it themselves. Getting \
    a word wrong there — a name, a term, a number — costs them more than a slightly awkward phrase.

    The user speaks only Russian and English: mostly Russian, often with English names and technical \
    terms inside it, which they write in Latin script ("закинул PR в anna-voice-messages"). Sometimes \
    a whole phrase in English.

    THE RECORDING DECIDES. What the versions heard is the evidence; the context only helps to choose \
    between them where they differ or are unsure, and to spell names and terms. Most of the time the \
    answer is simply the best version, cleaned up.

    You get:
    - <context>: where they are speaking — the app, the window, who they are, words they use, and \
      what the field already holds before the cursor.
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
    - A long dictation is the user's own wording: keep it, sentence by sentence, and only correct the \
      words that were misheard. Never summarise, rephrase or tidy it up.
    - It continues the text already in the field: if that ends mid-sentence, continue it (lowercase \
      start); match its style of punctuation — a chat message with no full stops gets none at the end.
    - A single short word or interjection ("Ура", "Да", "Ок", "Спасибо") is a real dictation, not noise.
    - A version from Apple's dictation is a different recogniser: Russian only, no probabilities, \
      English comes out mangled in it, but where it agrees with a whisper version they're both right.
    - Answer an empty text only when the versions are plainly noise — recogniser phantoms that \
      disagree with each other. Words the versions agree on were said, even if they make little \
      sense to you or the context doesn't explain them: type them.

    Reply with ONE JSON object and nothing else:
    {"reasoning": "<at most 8 words: which rule decided>", "text": "<what the user said>"}
    """

    private static func settle(_ versions: [Version], prompts: [String: String], context: ContextSnapshot.Gathered?) -> (String?, [String: Any]) {
        var block = ""
        // The screen itself stays out: the prefix already distilled it, and a page of it pulls the
        // model away from what was heard.
        if let context { block += "<context>\n\(context.described(screenLimit: 0, fieldLimit: 500))\n</context>\n\n" }
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
        let reply = Box()
        Task {
            defer { done.signal() }
            do {
                reply.value = try await LLMClient.complete(system: system, messages: [["role": "user", "content": block]], maxTokens: 400)
            } catch {
                log.error("dictation: settling failed: \(String(describing: error), privacy: .public)")
            }
        }
        // A slow model costs the user more than an unsettled version does.
        if done.wait(timeout: .now() + settleTimeout) == .timedOut {
            log.error("dictation: the model took over \(settleTimeout, privacy: .public)s — typing the first version")
            settlement["timed_out"] = settleTimeout
        }
        let raw = reply.value
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
