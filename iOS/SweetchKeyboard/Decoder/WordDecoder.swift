import CoreGraphics
import Foundation

/// From taps to the word they were meant to type: a beam search over the lexicon, one tap at a
/// time, as Android's LatinIME does it (Apache 2.0; its costs are the starting point here, to be
/// tuned on the user's own logged taps — see Tools/keyboard/replay).
///
/// Each tap is a spread over the keys near it, cheapest where it landed. A hypothesis — a place in
/// the lexicon and what it cost to get there — goes on by the letters the next tap could be, or by
/// an error: a letter never tapped (omission), a tap that typed nothing meant (insertion), two
/// letters swapped (transposition), a key far off (substitution). Words that end where the taps do
/// are scored with how common they are; the literal — the keys the taps landed on — always
/// competes, so a word the lexicon lacks is never forced into one it has.
final class WordDecoder {
    struct Key {
        let letter: Character
        let frame: CGRect
        /// Where this user's finger lands on the key, from its centre: the match cost is measured
        /// from the centre moved by it. The literal — the key a tap landed on — stays by the drawn
        /// borders, so a tap well inside a key is still that key's (the anchor).
        var offset: CGVector = .zero
    }

    struct Tap {
        let point: CGPoint
        let keys: [Key]
        /// Held, slid, or picked from the alternates: the user looked — it's what they meant.
        let deliberate: Bool
    }

    struct Costs {
        var match: Float = 0.1524          // × how far from the key's centre (0…1.2)
        var proximity: Float = 0.0694      // a key the tap didn't land on
        var omission: Float = 0.467        // a letter of the word never tapped
        var markOmission: Float = 0.1      // a hyphen or apostrophe never typed
        var insertion: Float = 0.7248      // a tap that's in no letter of the word
        var transposition: Float = 0.5608  // two letters typed swapped
        var substitution: Float = 0.3806   // a key nowhere near
        /// And more the farther it is: per key width between the tap and the key's edge, beyond
        /// the first. «й» typed for «е», four keys off, can't have been meant — LatinIME's flat
        /// price for any miss let a commoner word win over the one under the finger
        /// («осмвсленный» → «осмысленные», 19 Oct). A vowel for a vowel is exempt. On the bench
        /// (19 Oct, 1453 words): the user's own fixes 77 right / 18 wrong against 76 / 21, the top
        /// pick the word 6 times more; 0.35–0.8 alike, the mildest taken.
        var distance: Float = 0.35
        var language: Float = 1.1214       // × how uncommon the word is
        var maxEdits = 2
        var beam = 170
    }

    struct Candidate {
        let word: String
        let cost: Float
        let edits: Int
        let frequency: Int
    }

    struct Result {
        let literal: String
        let literalIsWord: Bool
        let candidates: [Candidate]
        /// What to type instead of the literal, when sure enough (see `threshold`).
        let correction: String?
        let confidence: Float
    }

    let lexicon: Lexicon
    /// Words likelier after others; without it, only how common each word is counts.
    let bigrams: Bigrams?
    /// The next words after one word or two, for the predictions; nil: from the bigrams.
    var nextWords: NextWords?
    /// How much a word used lately is lifted (0–15, as a word pair's): 12 on the bench's held-out
    /// day (18 Oct 2026) saved 19.4% of keystrokes against 18.6% at the old 4, broke nothing more;
    /// 15 began to spoil next-word predictions.
    var recentLift = 12
    /// How far a word likely after the two before it is lifted: to 255 + this × log₂ of its
    /// probability there, when that's above its own frequency. 0: not at all.
    /// On the bench (21 Oct): 8 put the word first among the suggestions earlier for 10 more words
    /// and two more of the user's fixes right, nothing broken; 16–32 the same or a little less.
    var nextWordScale: Float = 8
    /// How many of the likeliest next words are lifted.
    var nextWordLimit = 8
    var costs = Costs()
    /// LatinIME's "modest" autocorrection threshold on its normalised score.
    var threshold: Float = 0.185
    /// The correction is the candidate the decoder is surest of — its score scaled down by how far
    /// it is from the literal — not just the cheapest: "потм" is "потом" (a letter left out), not
    /// "моим" (two keys missed), though "моим" fits the taps a little better.
    var byConfidence = false

    init(lexicon: Lexicon, bigrams: Bigrams? = nil) {
        self.lexicon = lexicon
        self.bigrams = bigrams
    }

    /// The word before, for context: its lexicon node (0: a sentence starts), and the words typed
    /// lately (their nodes), which are likelier again.
    struct Context {
        var previous: Int?
        /// The word before that (0: a sentence starts before `previous`); nil when unknown.
        var previous2: Int?
        /// The next words likeliest after those two (node → probability), filled in by `decode`.
        var next: [Int: Float]?
        var recent: Set<Int> = []
        /// The words the user types on the phone (node → lift, 0–255).
        var boosts: [Int: Int] = [:]
    }

    /// How common a word is here, 0–255: its own frequency, lifted toward 255 by how much likelier
    /// it is after the word before (LatinIME's bigram scale: 16.5 steps between the two).
    func likelihood(_ node: Int, _ context: Context) -> Float {
        var frequency = Float(lexicon.frequency(node))
        if let boost = context.boosts[node] { frequency = min(255, frequency + Float(boost)) }
        var lift = 0
        if let previous = context.previous, let bigrams { lift = bigrams.weight(of: node, after: previous) }
        if context.recent.contains(node) { lift = max(lift, recentLift) }
        let lifted = lift > 0 ? frequency + Float(lift + 1) * (255 - frequency) / 16.5 : frequency
        guard nextWordScale > 0, let p = context.next?[node] else { return lifted }
        return max(lifted, min(255, 255 + nextWordScale * log2(p)))
    }

    /// What the strip offers while a word is typed: the words likeliest after the two before it
    /// that the letters typed begin, then the decoder's own (its words for the taps, and the words
    /// they begin). From the first letter on: on the held-out words of 21–22 Oct the word was among
    /// the three after one letter 15% of the time (1% from the decoder alone), after two 41% (30%).
    func completions(_ taps: [Tap], context: Context, limit: Int = 3) -> [String] {
        var shown: [String] = []
        func add(_ word: String) {
            guard shown.count < limit, !shown.contains(where: { $0.lowercased() == word.lowercased() }) else { return }
            shown.append(word)
        }
        let result = decode(taps, complete: true, context: context)
        if let nextWords, let previous = context.previous, !taps.isEmpty {
            let prefix = result.literal.lowercased()
            for (node, _) in nextWords.predict(after: context.previous2, previous, limit: 36) {
                let word = lexicon.word(at: node)
                if word.lowercased().hasPrefix(prefix) { add(word) }
            }
        }
        for candidate in result.candidates { add(candidate.word) }
        return shown
    }

    /// The likeliest next words before a letter is typed: those seen after the word before.
    func predictions(_ context: Context, limit: Int = 3) -> [String] {
        if let nextWords, let previous = context.previous {
            return nextWords.predict(after: context.previous2, previous, limit: limit).map { lexicon.word(at: $0.word) }
        }
        guard let previous = context.previous, let bigrams else { return [] }
        let words = bigrams.next(after: previous, limit: 24).map(\.word)
        return Array(Set(words))
            .map { ($0, likelihood($0, context)) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { lexicon.word(at: $0.0) }
    }

    private struct Hypothesis {
        var node: Int
        var cost: Float
        var edits: Int
        var path: [UInt8]
    }

    /// For one tap: what typing each letter near it costs, and the letter it landed on.
    private struct Spread {
        var cost: [UInt8: Float] = [:]
        /// How far the tap is from each letter's key, in key widths from its edge.
        var far: [UInt8: Float] = [:]
        var landed: Character = " "
        var landedCost: Float = 0
    }

    private func spread(_ tap: Tap) -> Spread {
        var spread = Spread()
        var nearest: (Character, Float)?
        let width = tap.keys.map(\.frame.width).min() ?? 30
        for key in tap.keys {
            let f = key.frame
            let dx = (tap.point.x - f.midX - key.offset.dx) / (f.width / 2), dy = (tap.point.y - f.midY - key.offset.dy) / (f.height / 2)
            let squared = Float(dx * dx + dy * dy)
            let px = (tap.point.x - f.midX) / (f.width / 2), py = (tap.point.y - f.midY) / (f.height / 2)
            let plain = Float(px * px + py * py)
            // Near enough to have been meant: within a key's width of its edge.
            let edgeX = max(f.minX - tap.point.x, tap.point.x - f.maxX, 0), edgeY = max(f.minY - tap.point.y, tap.point.y - f.maxY, 0)
            for letter in Self.variants(of: key.letter) {
                if let index = lexicon.index(of: letter.0) { spread.far[index] = Float(hypot(edgeX, edgeY) / width) }
            }
            guard hypot(edgeX, edgeY) < width else { continue }
            let factor = Self.sweetSpot(squared)
            let inside = f.contains(tap.point)
            let cost = costs.match * factor + (inside ? 0 : costs.proximity)
            if nearest == nil || plain < nearest!.1 { nearest = (key.letter, plain) }
            for letter in Self.variants(of: key.letter) {
                guard let index = lexicon.index(of: letter.0) else { continue }
                let total = cost + letter.1
                if total < spread.cost[index] ?? .infinity { spread.cost[index] = total }
            }
        }
        if let nearest {
            spread.landed = nearest.0
            spread.landedCost = spread.cost[lexicon.index(of: nearest.0) ?? 0] ?? 0
        }
        // The key the user picked deliberately is the only one.
        if tap.deliberate, let only = lexicon.index(of: spread.landed) {
            spread.cost = [only: 0]
        }
        return spread
    }

    private static let vowels: Set<Character> = Set("аеёиоуыэюяaeiouy")
    nonisolated(unsafe) private static var vowelNodeCache: Set<UInt8>?
    private static func vowelNodes(_ lexicon: Lexicon) -> Set<UInt8> {
        if let cached = vowelNodeCache { return cached }
        let set = Set(vowels.compactMap { lexicon.index(of: $0) })
        vowelNodeCache = set
        return set
    }

    /// Letters a key types: е is also ё, ь is also ъ (both on the key, held).
    private static func variants(of letter: Character) -> [(Character, Float)] {
        switch letter {
        case "е": [("е", 0), ("ё", 0)]
        case "ь": [("ь", 0), ("ъ", 0.1)]
        default: [(letter, 0)]
        }
    }

    /// LatinIME's curve from a tap's squared distance from the key's centre (in half-keys) to how
    /// unlike that key it is.
    private static func sweetSpot(_ squared: Float) -> Float {
        if squared <= 0.25 { return squared * 0.96 }
        if squared <= 1 { return 0.24 + (squared - 0.25) * (0.96 / 0.75) }
        return 1.2
    }

    /// `complete`: also words the taps so far begin — for suggestions while the word is typed.
    func decode(_ taps: [Tap], complete: Bool = false, context: Context = Context()) -> Result {
        var context = context
        if nextWordScale > 0, context.next == nil, let nextWords, let previous = context.previous {
            context.next = Dictionary(nextWords.predict(after: context.previous2, previous, limit: nextWordLimit).map { ($0.word, $0.p) }) { a, _ in a }
        }
        let spreads = taps.map(spread)
        let literal = String(spreads.map(\.landed))
        let literalNode = lexicon.lookup(literal)
        guard !taps.isEmpty else {
            return Result(literal: "", literalIsWord: false, candidates: [], correction: nil, confidence: 0)
        }
        let hyphen = lexicon.index(of: "-"), apostrophe = lexicon.index(of: "'")
        var beams = [[Hypothesis]](repeating: [], count: taps.count + 1)
        beams[0] = [Hypothesis(node: 0, cost: 0, edits: 0, path: [])]

        for position in 0..<taps.count {
            beams[position].sort { $0.cost < $1.cost }
            if beams[position].count > costs.beam { beams[position].removeLast(beams[position].count - costs.beam) }
            let here = spreads[position]
            let next = position + 1 < spreads.count ? spreads[position + 1] : nil
            for hypothesis in beams[position] {
                let canErr = hypothesis.edits < costs.maxEdits
                for child in lexicon.children(hypothesis.node) {
                    let letter = lexicon.label(child)
                    if let cost = here.cost[letter] {
                        beams[position + 1].append(Hypothesis(node: child, cost: hypothesis.cost + cost,
                                                              edits: hypothesis.edits, path: hypothesis.path + [letter]))
                    } else if canErr, !taps[position].deliberate {
                        // A vowel for a vowel is a slip of spelling as often as of the finger
                        // («упеминания», «добежале») — the distance tells nothing there; a letter not
                        // on the keys (the apostrophe) has none.
                        let spelling = Self.vowels.contains(here.landed) && Self.vowelNodes(lexicon).contains(letter)
                        let off = spelling ? 0 : max(0, (here.far[letter] ?? 1) - 1)
                        beams[position + 1].append(Hypothesis(node: child, cost: hypothesis.cost + costs.substitution + costs.match * 1.2 + costs.distance * off,
                                                              edits: hypothesis.edits + 1, path: hypothesis.path + [letter]))
                    }
                    // A letter never typed: this child is skipped, its child takes the tap.
                    let mark = letter == hyphen || letter == apostrophe
                    if canErr || mark {
                        for grandchild in lexicon.children(child) {
                            let second = lexicon.label(grandchild)
                            guard let cost = here.cost[second] else { continue }
                            beams[position + 1].append(Hypothesis(
                                node: grandchild, cost: hypothesis.cost + (mark ? costs.markOmission : costs.omission) + cost,
                                edits: hypothesis.edits + (mark ? 0 : 1), path: hypothesis.path + [letter, second]))
                        }
                    }
                    // Two letters swapped: this child takes the next tap, its child this one.
                    if canErr, let next, let first = next.cost[letter] {
                        for grandchild in lexicon.children(child) {
                            let second = lexicon.label(grandchild)
                            guard let cost = here.cost[second] else { continue }
                            beams[position + 2].append(Hypothesis(
                                node: grandchild, cost: hypothesis.cost + costs.transposition + first + cost,
                                edits: hypothesis.edits + 1, path: hypothesis.path + [letter, second]))
                        }
                    }
                }
                // A tap that's in no letter of the word.
                if canErr, !taps[position].deliberate {
                    beams[position + 1].append(Hypothesis(node: hypothesis.node, cost: hypothesis.cost + costs.insertion + here.landedCost,
                                                          edits: hypothesis.edits + 1, path: hypothesis.path))
                }
            }
        }

        // Words that end where the taps do — or one letter on, the last one never typed.
        var best: [Int: Candidate] = [:]
        func consider(_ node: Int, _ cost: Float, _ edits: Int, _ path: [UInt8]) {
            let frequency = Int(lexicon.frequency(node))
            guard frequency > 0 else { return }
            let total = cost + costs.language * (255 - likelihood(node, context)) / 255
            if total < best[node]?.cost ?? .infinity {
                best[node] = Candidate(word: lexicon.word(path, node: node), cost: total, edits: edits, frequency: frequency)
            }
        }
        for hypothesis in beams[taps.count] {
            consider(hypothesis.node, hypothesis.cost, hypothesis.edits, hypothesis.path)
            if hypothesis.edits < costs.maxEdits {
                for child in lexicon.children(hypothesis.node) {
                    consider(child, hypothesis.cost + costs.omission, hypothesis.edits + 1, hypothesis.path + [lexicon.label(child)])
                }
            }
        }
        // Words the taps begin: the nearest ends below the best places reached, a little dearer per
        // letter not yet typed (cheaper than LatinIME's: typing a word's start is no error).
        if complete {
            for hypothesis in beams[taps.count].sorted(by: { $0.cost < $1.cost }).prefix(12) {
                var queue: [(node: Int, path: [UInt8], depth: Int)] = [(hypothesis.node, hypothesis.path, 0)]
                var head = 0
                while head < queue.count, head < 400 {
                    let (node, path, depth) = queue[head]
                    head += 1
                    if depth > 0 { consider(node, hypothesis.cost + 0.2 + 0.01 * Float(depth - 1), hypothesis.edits, path) }
                    guard depth < 8 else { continue }
                    for child in lexicon.children(node) { queue.append((child, path + [lexicon.label(child)], depth + 1)) }
                }
            }
        }
        let candidates = best.values.sorted { $0.cost < $1.cost }.prefix(8)

        // LatinIME's decision: the best word's score, scaled down by how far it is from the literal.
        var correction: String?
        var confidence: Float = 0
        func sureness(_ c: Candidate) -> Float {
            let score = 1 - c.cost / (costs.language + 0.1 * Float(taps.count))
            let distance = Float(Self.damerauLevenshtein(literal.lowercased(), c.word.lowercased()))
            return score * (1 - distance / Float(max(c.word.count, 1)))
        }
        let pick = byConfidence
            ? candidates.prefix(3).filter { $0.word.lowercased() != literal.lowercased() }.max { sureness($0) < sureness($1) }
            : candidates.first
        if let top = pick, top.word.lowercased() != literal.lowercased() {
            confidence = sureness(top)
            // A short Latin word is an abbreviation more often than a typo ("ux", "pr", "ci").
            let abbreviation = literal.count <= 3 && literal.unicodeScalars.allSatisfy { $0.isASCII }
            // A name for a word typed small: «пише» isn't «Мише» (19 Oct, taken back) — a name is typed
            // with its capital, and a small letter means a common word was meant.
            let toName = top.word.first?.isUppercase == true && literal.first?.isLowercase == true
            let mayCorrect = literalNode == nil && literal.count > 1 && !abbreviation && !toName && !taps.contains(where: \.deliberate)
            if mayCorrect, confidence >= threshold { correction = top.word }
        }
        return Result(literal: literal, literalIsWord: literalNode != nil, candidates: Array(candidates),
                      correction: correction, confidence: confidence)
    }

    static func damerauLevenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
}
