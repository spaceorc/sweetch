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
        ]
        var map: [String: String] = [:]
        for (emoji, words) in groups { for word in words { map[word] = emoji } }
        return map
    }()

    /// The emoji for `word`, if it says one thing — two or three, space-separated, the likeliest first.
    static func `for`(_ word: String) -> String? { byWord[word.lowercased()] }

    /// Whether a suggestion is an emoji rather than a word.
    static func isEmoji(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
    }
}
