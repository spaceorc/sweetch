import Foundation

/// Russian words that are written with a hyphen and typed without one — «чтото», «какойнибудь»,
/// «всетаки», «подругому», «изза» — put right as the word ends, as a phone's own keyboard would. Only
/// shapes that can't be anything else: a particle after a question word, кое- before one, по- before
/// the adverbs that take it (a list: «поэтому», «почему» look the same and aren't), из-за, из-под.
enum Hyphens {
    private static let questions = [
        "что", "чего", "чему", "чем", "чём", "кто", "кого", "кому", "кем", "ком", "как", "где", "куда", "откуда",
        "когда", "почему", "зачем", "сколько", "чей", "чья", "чьё", "чьи", "чьего", "чьей", "чьим", "чьих",
        "какой", "какая", "какое", "какие", "какую", "каких", "какого", "каком", "каким", "какими", "какому", "какою",
    ]
    private static let kaBases = ["давай", "давайте", "скажи", "смотри", "посмотри", "подожди", "дай", "ну", "иди", "покажи", "попробуй"]
    private static let poAdverbs: Set<String> = [
        "другому", "хорошему", "плохому", "моему", "твоему", "своему", "нашему", "вашему", "новому", "старому",
        "разному", "всякому", "любому", "прежнему", "настоящему", "нормальному", "честному", "простому", "иному",
        "взрослому", "умному", "быстрому", "человечески", "русски", "английски", "французски", "немецки",
        "украински", "грузински", "дружески", "детски", "братски", "отечески", "соседски", "тихому", "серьёзному",
        "серьезному", "доброму", "видимому", "прежнему", "моему", "летнему", "зимнему", "весеннему", "осеннему",
    ]

    /// The word as it's written, or nil when it's fine as typed. Capitals stay where they were.
    static func fix(_ word: String) -> String? {
        let lower = word.lowercased()
        func hyphen(at count: Int) -> String {
            let chars = Array(word)
            return String(chars[..<count]) + "-" + String(chars[count...])
        }
        for particle in ["нибудь", "либо", "то"] where lower.hasSuffix(particle) {
            let base = String(lower.dropLast(particle.count))
            if questions.contains(base) || base == "вообще" || base == "ну" { return hyphen(at: base.count) }
        }
        if lower.hasSuffix("таки"), ["все", "всё", "так", "опять", "верно", "неужели", "довольно"].contains(String(lower.dropLast(4))) {
            return hyphen(at: lower.count - 4)
        }
        if lower.hasSuffix("ка"), kaBases.contains(String(lower.dropLast(2))) { return hyphen(at: lower.count - 2) }
        if lower.hasPrefix("кое"), questions.contains(String(lower.dropFirst(3))) { return hyphen(at: 3) }
        if lower.hasPrefix("по"), poAdverbs.contains(String(lower.dropFirst(2))) { return hyphen(at: 2) }
        if lower == "изза" || lower == "изпод" { return hyphen(at: 2) }
        return nil
    }
}
