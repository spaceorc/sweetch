import Foundation

/// Words typed in the wrong layout, put in the other — as the space after one comes (`automatic`),
/// or on ⌥Space. Read off the keys, in each layout as the layouts themselves type them, and
/// weighed against the keyboard's lexicon (iOS/SweetchKeyboard/Lexicon.bin, the same file): a word
/// is in the wrong layout when its keys make no word in the layout it was typed in, or a far rarer
/// one, and a common word in the other (Mac bench, `replay --layouts 100 2 --margin 120`, 4 days:
/// 120 of the user's 133 layout fixes, 1–3 real words of 5233 switched). The words typed just
/// before it in one go (no click, arrow or switch — the buffer keeps them), in the same layout, go
/// along when the other layout suits them no worse: «yt pyf» goes over whole.
///
/// A switch taken back with ⌥Space is the word kept as typed from then on (UserDefaults).
final class AutoLayout {
    /// How common a word in the other layout must be (the lexicon's 0–255) to switch to it…
    static let minFrequency = 100
    /// …and by how much commoner than what the keys make in theirs, when that's a word too.
    static let margin = 120
    /// The words of one go: keys no further apart than this (the buffer forgets after 10 s anyway).
    static let session: TimeInterval = 10

    struct Word {
        let range: Range<Int>
        let own: String
        let other: String
        let ownFrequency: Int
        let otherFrequency: Int
        let sourceID: String
    }

    private lazy var lexicon: Lexicon? = Bundle.main.url(forResource: "Lexicon", withExtension: "bin").flatMap(Lexicon.init)
    private static let keptKey = "layoutKept"
    private var kept = Set(UserDefaults.standard.stringArray(forKey: keptKey) ?? [])

    /// The keystrokes to put in the other layout: the last word and those of the same go before it
    /// that suit it no worse, to the end of the buffer (the space after included). Automatic: only
    /// when the last word is plainly in the wrong layout; on ⌥Space the last word goes regardless.
    /// `knownStart`: the buffer's first keystroke begins a word; when not, a word starting there may
    /// be the end of one on the screen, and isn't switched on its own.
    func range(in keys: [Keystroke], automatic: Bool, knownStart: Bool = true) -> Range<Int>? {
        let words = self.words(in: keys)
        guard let last = words.last else { return nil }
        if automatic {
            guard knownStart || last.range.lowerBound > 0 else { return nil }
            guard last.own.count >= 2, !kept.contains(last.own.lowercased()), plainlyWrong(last) else { return nil }
        }
        // The whole go of typing, not the word alone: nothing switched, no window changed, the
        // layout was wrong for all of it — but for a word right in its own layout and no word in
        // the other, which ends it («почему», then an English word typed in Russian). On 5 days
        // that's 1 more of the user's 249 wrong-layout words than the word alone, and 1 real word
        // broken (`replay --layout-runs`, any pause): wrong-layout words are mostly told one by
        // one — the go is for the short ones that aren't («yt», «щт»).
        var start = last.range.lowerBound
        for word in words.dropLast().reversed() {
            guard word.sourceID == last.sourceID, !kept.contains(word.own.lowercased()),
                  word.otherFrequency > 0, word.otherFrequency >= word.ownFrequency else { break }
            start = word.range.lowerBound
        }
        return start..<keys.count
    }

    /// The user took a switch back: those words stay as typed.
    func keep(_ keys: [Keystroke], range: Range<Int>) {
        for word in words(in: Array(keys[range])) { kept.insert(word.other.lowercased()) }
        UserDefaults.standard.set(Array(kept), forKey: Self.keptKey)
    }

    private func plainlyWrong(_ w: Word) -> Bool {
        w.otherFrequency >= Self.minFrequency && (w.ownFrequency == 0 || w.ownFrequency + Self.margin <= w.otherFrequency)
    }

    /// The words of the last go, oldest first: runs of keys between spaces, each read in both layouts.
    func words(in keys: [Keystroke]) -> [Word] {
        guard let lexicon else { return [] }
        let chars = LayoutTranslator.keyChars()
        var words: [Word] = []
        var end = keys.count
        while end > 0 {
            while end > 0, keys[end - 1].keyCode == 49 { end -= 1 }
            var start = end
            while start > 0, keys[start - 1].keyCode != 49 { start -= 1 }
            guard start < end else { break }
            let word = Array(keys[start..<end])
            if let after = words.first, keys[after.range.lowerBound].timestamp.timeIntervalSince(word.last!.timestamp) > Self.session { break }
            guard Set(word.map(\.sourceID)).count == 1 else { break }
            let secondary = InputSourceSwitcher.secondaryIDs.contains(word[0].sourceID)
            let read = { (map: [Int: Character]) -> String in
                String(word.compactMap { map[Int($0.keyCode) | ($0.flags.contains(.maskShift) ? 0x100 : 0)] })
            }
            let own = Self.letters(read(secondary ? chars.secondary : chars.primary))
            let other = Self.letters(read(secondary ? chars.primary : chars.secondary))
            guard !own.isEmpty || !other.isEmpty else { break }
            let frequency = { (w: String) in lexicon.lookup(w.lowercased()).map { Int(lexicon.frequency($0)) } ?? 0 }
            words.insert(Word(range: start..<end, own: own, other: other, ownFrequency: frequency(own),
                              otherFrequency: frequency(other), sourceID: word[0].sourceID), at: 0)
            end = start
        }
        return words
    }

    /// The word without what's around it: «pyf.» is «pyf», «знаю» stays.
    private static func letters(_ s: String) -> String {
        let isPart: (Character) -> Bool = { $0.isLetter || $0 == "-" || $0 == "'" }
        return String(s.drop { !isPart($0) }.reversed().drop { !isPart($0) }.reversed())
    }
}
