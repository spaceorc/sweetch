import Foundation

/// Emoji for a word — «спасибо» 🙏 👍 ❤️, «ок» 👌 👍, «круто» 🔥 😎 👍 — offered together in the
/// strip's last place: while the word is typed a tap puts the emoji in its place; after the word
/// (a space typed) a tap adds it at the end. The
/// system's emoji keyboard is there for the rest. Only words that say one thing: «да», «нет»,
/// «хорошо» would be everywhere and mean nothing.
enum Emoji {
    private static let byWord: [String: String] = {
        let groups: [(String, [String])] = [
            ("🙏 👍 ❤️", ["спасибо", "спс", "благодарю", "thanks", "thank", "thx"]),
            ("🙏 🥺", ["пожалуйста", "please"]),
            ("👌 👍", ["ок", "окей", "ok", "okay"]),
            ("👍 🤝 ✅", ["отлично", "договорились", "принято", "согласен", "согласна", "nice", "agreed", "deal"]),
            ("🔥 😎 👍", ["круто", "огонь", "мощно", "fire", "awesome", "amazing"]),
            ("😎 👍 🔥", ["класс", "кайф", "cool"]),
            ("😂 🤣 😄", ["смешно", "ахаха", "хаха", "ахахах", "ржу", "lol", "lmao", "haha", "funny"]),
            ("😢 😔", ["грустно", "жаль", "печально", "sad"]),
            ("😔 🙏", ["извини", "прости", "простите", "извините", "sorry"]),
            ("😮 🤯", ["ого", "вау", "wow"]),
            ("🤔", ["хм", "хмм", "думаю", "интересно", "hmm"]),
            ("🎉 🥳 🍾", ["ура", "поздравляю", "поздравляем", "congrats", "congratulations", "yay"]),
            ("❤️ 😍 🥰", ["люблю", "обожаю", "сердце", "love"]),
            ("👋 🙂", ["привет", "пока", "здравствуйте", "hi", "hello", "hey", "bye"]),
            ("😴 🛌", ["спать", "сплю", "устал", "устала", "sleep", "tired"]),
            ("☕", ["кофе", "coffee"]),
            ("🍕", ["пицца", "pizza"]),
            ("🍺 🍻", ["пиво", "beer"]),
            ("🍷 🥂", ["вино", "wine"]),
            ("🎂 🎉", ["торт", "др", "cake", "birthday"]),
            ("🌧 ☔", ["дождь", "дожди", "rain"]),
            ("☀️ 😎", ["солнце", "солнечно", "sun", "sunny"]),
            ("❄️ 🥶", ["снег", "холодно", "snow", "cold"]),
            ("💰 💸", ["деньги", "money"]),
            ("🚗", ["машина", "машине", "car"]),
            ("🚆", ["поезд", "поезде", "электричка", "train"]),
            ("✈️", ["самолёт", "самолет", "самолете", "самолёте", "рейс", "flight", "plane"]),
            ("🏠", ["дома", "домой", "home"]),
            ("🐱", ["кот", "кошка", "котик", "cat"]),
            ("🐶", ["собака", "пёс", "пес", "dog"]),
            ("💻", ["ноутбук", "компьютер", "laptop"]),
            ("📱", ["телефон", "phone"]),
            ("🤝 📞", ["встреча", "созвон", "meeting", "call"]),
            ("🚀 🎉", ["релиз", "задеплоил", "выкатил", "release", "shipped", "launch"]),
            ("🐛 😬", ["баг", "bug"]),
            ("✅ 👍", ["готово", "сделал", "сделала", "done"]),
            // Smileys typed as text: the emoji they stand for, in their place.
            ("🙂 😊", [":)", ":-)", "(:"]),
            ("😄 😂", [":d", ":-d"]),
            ("🙁 😔", [":(", ":-("]),
            ("😢 😭", [":'("]),
            ("😉", [";)", ";-)"]),
            ("😛 😜", [":p", ":-p"]),
            ("😘", [":*", ":-*"]),
            ("😮", [":o", ":-o"]),
            ("😐", [":|", ":-|"]),
            ("❤️", ["<3"]),
        ]
        var map: [String: String] = [:]
        for (emoji, words) in groups { for word in words { map[word] = emoji } }
        return map
    }()

    /// The text smiley the text ends with — «:)», «;-)», «<3» — after a space or at the start.
    static func smiley(endOf text: String) -> String? {
        let last = String(text.reversed().prefix { !$0.isWhitespace }.reversed())
        guard last.count >= 2, !last.allSatisfy(\.isLetter), byWord[last.lowercased()] != nil else { return nil }
        return last
    }

    /// The emoji that come with `word`, as they came, likeliest first.
    static func defaults(_ word: String) -> [String] {
        byWord[word.lowercased()].map { $0.split(separator: " ").map(String.init) } ?? []
    }

    /// The emoji to offer for `word`, best first, at most three: those the user picked for it, then
    /// those they put after it themselves, then the ones it came with — never one they hid; each in
    /// the skin tone they chose. A word of no emoji of its own gets those the user put after it twice.
    static func ranked(for word: String, memory: EmojiMemory = .shared) -> [String] {
        let key = word.lowercased()
        let base = defaults(key)
        var score: [String: Double] = [:]
        for (i, e) in base.enumerated() { score[e, default: 0] += 1 - Double(i) * 0.1 }
        for (e, n) in memory.typedAfter[key] ?? [:] where n >= 2 || base.contains(e) { score[e, default: 0] += 1.5 * Double(n) }
        for (e, n) in memory.picked[key] ?? [:] { score[e, default: 0] += 2 * Double(n) }
        for (e, n) in memory.picked[EmojiMemory.any] ?? [:] where score[e] != nil { score[e]! += 0.2 * Double(n) }
        return score.filter { !memory.isHidden($0.key, for: key) }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map { memory.tones[$0.key] ?? $0.key }
    }

    private static let tones: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF

    /// The emoji without a skin tone (and without the presentation selector a tone replaces).
    static func base(of emoji: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: emoji.unicodeScalars.filter { !tones.contains($0.value) })
        let plain = String(scalars)
        return byToned[plain] ?? plain
    }
    /// «👍» and «👍🏽» are one emoji to remember; a toned one written without its selector maps back.
    private static let byToned: [String: String] = [:]

    /// The emoji in every skin tone, plain first — nil for one that takes no tone.
    static func toneVariants(_ emoji: String) -> [String]? {
        let plain = base(of: emoji)
        let core = plain.unicodeScalars.filter { $0.value != 0xFE0F }
        guard core.count == 1, let first = core.first, first.properties.isEmojiModifierBase else { return nil }
        let b = String(first)
        return [plain] + tones.map { b + String(UnicodeScalar($0)!) }
    }

    /// Whether a suggestion is an emoji rather than a word.
    static func isEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }
}
