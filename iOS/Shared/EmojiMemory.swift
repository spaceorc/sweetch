import Foundation

/// What the user does with emoji, kept in the app group so the app's Emoji screen sees and resets
/// it: the emoji picked from the strip for a word, the ones put after a word from the system's emoji
/// keyboard, the skin tone chosen for an emoji, and the ones never to show again — for a word, or
/// for any ("*"). The keyboard orders the strip's emoji by these (Emoji.ranked); nothing is kept
/// while it's incognito.
final class EmojiMemory {
    static let shared = EmojiMemory()

    private let defaults = UserDefaults(suiteName: SharedState.group) ?? .standard
    static let any = "*"

    /// word (lowercased) → emoji → how many times
    private(set) var picked: [String: [String: Int]]
    /// word (lowercased) → emoji → how many times, typed after it from the system's emoji keyboard
    private(set) var typedAfter: [String: [String: Int]]
    /// emoji as offered → with the tone the user chose
    private(set) var tones: [String: String]
    /// "word|emoji", or "*|emoji" for any word
    private(set) var hidden: Set<String>

    private init() {
        picked = defaults.dictionary(forKey: "emojiPicked") as? [String: [String: Int]] ?? [:]
        typedAfter = defaults.dictionary(forKey: "emojiTypedAfter") as? [String: [String: Int]] ?? [:]
        tones = defaults.dictionary(forKey: "emojiTones") as? [String: String] ?? [:]
        hidden = Set(defaults.stringArray(forKey: "emojiHidden") ?? [])
    }

    /// Read again — the app or the keyboard may have changed it meanwhile.
    func reload() {
        picked = defaults.dictionary(forKey: "emojiPicked") as? [String: [String: Int]] ?? [:]
        typedAfter = defaults.dictionary(forKey: "emojiTypedAfter") as? [String: [String: Int]] ?? [:]
        tones = defaults.dictionary(forKey: "emojiTones") as? [String: String] ?? [:]
        hidden = Set(defaults.stringArray(forKey: "emojiHidden") ?? [])
    }

    func pick(_ emoji: String, for word: String) {
        let key = word.lowercased()
        picked[key, default: [:]][emoji, default: 0] += 1
        picked[Self.any, default: [:]][emoji, default: 0] += 1
        defaults.set(picked, forKey: "emojiPicked")
    }

    func typed(_ emoji: String, after word: String) {
        let key = word.lowercased()
        typedAfter[key, default: [:]][emoji, default: 0] += 1
        // Only the words used lately and often enough matter: the table stays small.
        if typedAfter.count > 400 {
            typedAfter = Dictionary(uniqueKeysWithValues: typedAfter.sorted { $0.value.values.reduce(0, +) > $1.value.values.reduce(0, +) }.prefix(300).map { ($0.key, $0.value) })
        }
        defaults.set(typedAfter, forKey: "emojiTypedAfter")
    }

    func setTone(_ toned: String, for emoji: String) {
        tones[emoji] = toned
        defaults.set(tones, forKey: "emojiTones")
    }

    func hide(_ emoji: String, for word: String?) {
        hidden.insert("\(word?.lowercased() ?? Self.any)|\(emoji)")
        defaults.set(Array(hidden), forKey: "emojiHidden")
    }

    func unhide(_ entry: String) {
        hidden.remove(entry)
        defaults.set(Array(hidden), forKey: "emojiHidden")
    }

    func forgetTone(of emoji: String) {
        tones[emoji] = nil
        defaults.set(tones, forKey: "emojiTones")
    }

    func isHidden(_ emoji: String, for word: String) -> Bool {
        hidden.contains("\(word.lowercased())|\(emoji)") || hidden.contains("\(Self.any)|\(emoji)")
    }

    /// Everything forgotten: the emoji as they came.
    func reset() {
        picked = [:]; typedAfter = [:]; tones = [:]; hidden = []
        for key in ["emojiPicked", "emojiTypedAfter", "emojiTones", "emojiHidden"] { defaults.removeObject(forKey: key) }
    }
}
