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
    var costs = Costs()
    /// LatinIME's "modest" autocorrection threshold on its normalised score.
    var threshold: Float = 0.185

    init(lexicon: Lexicon) { self.lexicon = lexicon }

    private struct Hypothesis {
        var node: Int
        var cost: Float
        var edits: Int
        var path: [UInt8]
    }

    /// For one tap: what typing each letter near it costs, and the letter it landed on.
    private struct Spread {
        var cost: [UInt8: Float] = [:]
        var landed: Character = " "
        var landedCost: Float = 0
    }

    private func spread(_ tap: Tap) -> Spread {
        var spread = Spread()
        var nearest: (Character, Float)?
        let width = tap.keys.map(\.frame.width).min() ?? 30
        for key in tap.keys {
            let f = key.frame
            let dx = (tap.point.x - f.midX) / (f.width / 2), dy = (tap.point.y - f.midY) / (f.height / 2)
            let squared = Float(dx * dx + dy * dy)
            // Near enough to have been meant: within a key's width of its edge.
            let edgeX = max(f.minX - tap.point.x, tap.point.x - f.maxX, 0), edgeY = max(f.minY - tap.point.y, tap.point.y - f.maxY, 0)
            guard hypot(edgeX, edgeY) < width else { continue }
            let factor = Self.sweetSpot(squared)
            let inside = f.contains(tap.point)
            let cost = costs.match * factor + (inside ? 0 : costs.proximity)
            if nearest == nil || squared < nearest!.1 { nearest = (key.letter, squared) }
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
    func decode(_ taps: [Tap], complete: Bool = false) -> Result {
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
                        beams[position + 1].append(Hypothesis(node: child, cost: hypothesis.cost + costs.substitution + costs.match * 1.2,
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
            let total = cost + costs.language * Float(255 - frequency) / 255
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
        if let top = candidates.first, top.word.lowercased() != literal.lowercased() {
            let score = 1 - top.cost / (costs.language + 0.1 * Float(taps.count))
            let distance = Float(Self.damerauLevenshtein(literal.lowercased(), top.word.lowercased()))
            confidence = score * (1 - distance / Float(max(top.word.count, 1)))
            let mayCorrect = literalNode == nil && literal.count > 1 && !taps.contains(where: \.deliberate)
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
