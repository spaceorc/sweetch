import Foundation

/// English contractions typed without the apostrophe — «im», «Ill», «dont», «didnt» — put right as
/// the word ends, as a phone's own keyboard would: the decoder had «I'll» first for «Ill» but «ill»
/// is a word, and «im» is short enough to pass for an abbreviation, so neither was touched and the
/// user typed them again by hand (19 Oct). Only shapes that can't be anything else: «its», «were»,
/// «well», «wed», «lets», «id», «hell», «shell» are words of their own and stay as typed.
enum Apostrophes {
    private static let forms: [String: String] = [
        "im": "I'm", "ive": "I've", "ill": "I'll",
        "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't", "arent": "aren't",
        "didnt": "didn't", "doesnt": "doesn't", "wasnt": "wasn't", "werent": "weren't",
        "havent": "haven't", "hasnt": "hasn't", "hadnt": "hadn't", "wouldnt": "wouldn't",
        "couldnt": "couldn't", "shouldnt": "shouldn't", "mustnt": "mustn't", "neednt": "needn't", "aint": "ain't",
        "youre": "you're", "youve": "you've", "youll": "you'll", "youd": "you'd",
        "theyre": "they're", "theyve": "they've", "theyll": "they'll", "theyd": "they'd",
        "weve": "we've", "shes": "she's", "hes": "he's", "itll": "it'll",
        "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's",
        "whos": "who's", "wheres": "where's", "hows": "how's", "yall": "y'all",
    ]

    /// The word as it's written, or nil when it's fine as typed. A capital stays a capital; «I» is
    /// always one.
    static func fix(_ word: String) -> String? {
        // «I» is always a capital: «i», «i'm», «i've» as typed, too.
        let lower = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if (lower == "i" || ["i'm", "i've", "i'll", "i'd"].contains(lower)), word.first == "i" {
            return "I" + word.dropFirst()
        }
        guard !word.contains("'"), !word.contains("’"), let form = forms[word.lowercased()] else { return nil }
        if form.hasPrefix("I'") { return form }
        guard let first = word.first, first.isUppercase else { return form }
        return form.prefix(1).uppercased() + form.dropFirst()
    }
}
