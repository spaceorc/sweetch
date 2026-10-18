import CoreGraphics
import Foundation

// The decoder (iOS/SweetchKeyboard/Decoder) run on the words typed on the keyboard
// (Tools/keyboard/export_words.py): on the words left as typed it must change nothing; on the ones
// the user put right it should find what they meant.
//
// Usage: replay <Lexicon.bin> <words.json> [--verbose]

struct Export: Decodable {
    struct Tap: Decodable { let char: String; let x: Double; let y: Double; let layout: String; let deliberate: Bool }
    struct Word: Decodable {
        let kind: String; let taps: [Tap]; let truth: String; let typed_is_word: Bool?
        let previous: String?; let sentence_start: Bool?
        /// The word after it in the text as it ended up, and whether its taps came fast.
        let next: String?; let fast: Bool?
    }
    let layouts: [String: [[Value]]]
    let words: [Word]
    enum Value: Decodable {
        case text(String), number(Double)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .text(s) } else { self = .number(try c.decode(Double.self)) }
        }
        var number: Double { if case .number(let n) = self { n } else { 0 } }
        var text: String { if case .text(let s) = self { s } else { "" } }
    }
}

let args = CommandLine.arguments
guard args.count >= 3, let lexicon = Lexicon(url: URL(fileURLWithPath: args[1])) else {
    print("usage: replay <Lexicon.bin> <words.json> [--verbose]"); exit(1)
}
let verbose = args.contains("--verbose")
let export = try JSONDecoder().decode(Export.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
// `--offsets <file.json>`: {letter: [dx, dy]} — where the user's finger lands on each key, for the
// decoder's match cost (WordDecoder.Key.offset).
let offsets: [String: [Double]] = args.firstIndex(of: "--offsets").flatMap { i in
    i + 1 < args.count ? (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))) as? [String: [Double]] : nil
} ?? [:]
let keys: [String: [WordDecoder.Key]] = export.layouts.mapValues { rows in
    rows.map {
        let o = offsets[$0[0].text] ?? [0, 0]
        return WordDecoder.Key(letter: Character($0[0].text), frame: CGRect(x: $0[1].number, y: $0[2].number, width: $0[3].number, height: $0[4].number),
                               offset: CGVector(dx: o[0], dy: o.count > 1 ? o[1] : 0))
    }
}
let bigrams = args.contains("--no-context") ? nil : Bigrams(url: URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("Bigrams.bin"))
var decoder = WordDecoder(lexicon: lexicon, bigrams: bigrams)
if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let t = Float(args[i + 1]) { decoder.threshold = t }
if let i = args.firstIndex(of: "--language"), i + 1 < args.count, let l = Float(args[i + 1]) { decoder.costs.language = l }

// `--bench <name>`: the bench — every measure at once, on the user's own typing, saved as
// build/bench/<name>.json for comparing variants (Tools/keyboard/bench_compare.py):
// - autocorrect: real words it would break, typos left in it would fix, the user's own fixes it
//   would make (and get wrong);
// - the second look at the previous word: put right and made wrong;
// - suggestions: each word replayed letter by letter, the decoder's three suggestions after each
//   (as the keyboard shows them, from two letters on) and the next-word predictions before the
//   first — how many letters before the end the word is first in the top three and first of
//   all, by length; keystrokes saved taking the first suggestion as soon as it's the word;
// - time per word.
if let i = args.firstIndex(of: "--bench"), i + 1 < args.count {
    let name = args[i + 1]
    var auto = (clean: 0, broke: 0, typosLeftFixed: 0, fixedWords: 0, madeRight: 0, madeWrong: 0)
    var post = (fixed: 0, broke: 0, looked: 0)
    struct Band { var words = 0, top3 = 0, top1 = 0, lettersSaved = 0, letters = 0, top1Left: [Int] = [] }
    var bands: [String: Band] = [:]
    var predicted = (words: 0, top3: 0, top1: 0)
    // `--recent <n>` / `--recent-lift <l>`: the last n words typed, lifted as the keyboard lifts its
    // recent words (it keeps 100).
    let recentCount = args.firstIndex(of: "--recent").flatMap { j in j + 1 < args.count ? Int(args[j + 1]) : nil } ?? 0
    if let j = args.firstIndex(of: "--recent-lift"), j + 1 < args.count, let l = Int(args[j + 1]) { decoder.recentLift = l }
    var typedSoFar: [Int] = []
    // The decoder's first pick against the word as it ended up, on every word the lexicon has.
    var accuracy = (words: 0, top1: 0, top3: 0, literalRight: 0)
    var started = Date()
    func band(_ n: Int) -> String { n <= 3 ? "2-3" : n <= 6 ? "4-6" : "7+" }
    for word in export.words {
        defer { if let node = lexicon.lookup(word.truth.lowercased()) { typedSoFar.append(node) } }
        guard word.taps.count >= 2 else { continue }
        let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        if recentCount > 0 { context.recent = Set(typedSoFar.suffix(recentCount)) }
        let truth = word.truth.lowercased(), typed = word.taps.map(\.char).joined().lowercased()
        let truthIsWord = lexicon.lookup(truth) != nil
        let result = decoder.decode(taps, context: context)
        let live = (result.correction ?? result.literal).lowercased()
        if truthIsWord, truth.count == taps.count {
            accuracy.words += 1
            if result.candidates.first?.word.lowercased() == truth { accuracy.top1 += 1 }
            if result.candidates.prefix(3).contains(where: { $0.word.lowercased() == truth }) { accuracy.top3 += 1 }
            if result.literal.lowercased() == truth { accuracy.literalRight += 1 }
        }
        // Autocorrect.
        if word.kind == "clean" {
            auto.clean += 1
            if let c = result.correction?.lowercased(), c != truth {
                if word.typed_is_word ?? truthIsWord { auto.broke += 1 } else { auto.typosLeftFixed += 1 }
            }
        } else {
            auto.fixedWords += 1
            if result.correction?.lowercased() == truth { auto.madeRight += 1 } else if result.correction != nil { auto.madeWrong += 1 }
        }
        // The second look, before the next word.
        if let bigrams, let next = word.next, let nextNode = lexicon.lookup(next.lowercased()),
           !result.literalIsWord || result.confidence > decoder.threshold * 0.5 {
            post.looked += 1
            let rescored = result.candidates.prefix(5).map { c -> (String, Float, Int) in
                let lift = lexicon.lookup(c.word.lowercased()).map { bigrams.weight(of: nextNode, after: $0) } ?? 0
                let f = Float(c.frequency)
                let lifted = lift > 0 ? min(255, f + Float(lift + 1) * (255 - f) / 16.5) : f
                return (c.word.lowercased(), c.cost - decoder.costs.language * (lifted - f) / 255, lift)
            }.sorted { $0.1 < $1.1 }
            if word.fast == true, let best = rescored.first, best.0 != live, best.2 >= 4 {
                if best.0 == truth { post.fixed += 1 } else if live == truth, truthIsWord { post.broke += 1 }
            }
        }
        // Suggestions, letter by letter — for words the lexicon has (a typo left in is no target).
        guard truthIsWord, truth.count >= 2, truth.count == taps.count || word.kind == "clean" else { continue }
        let n = truth.count
        var b = bands[band(n)] ?? Band()
        b.words += 1
        b.letters += n + 1
        if context.previous != nil {
            predicted.words += 1
            let p = decoder.predictions(context).map { $0.lowercased() }
            if p.contains(truth) { predicted.top3 += 1 }
            if p.first == truth { predicted.top1 += 1 }
        }
        var first3: Int?, first1: Int?
        if word.kind == "clean" {
            for k in 2..<n {
                let r = decoder.decode(Array(taps.prefix(k)), complete: true, context: context)
                var shown: [String] = []
                for c in r.candidates where !shown.contains(c.word.lowercased()) {
                    shown.append(c.word.lowercased())
                    if shown.count == 3 { break }
                }
                if first3 == nil, shown.contains(truth) { first3 = n - k }
                if shown.first == truth { first1 = n - k; break }
            }
        }
        if first3 != nil { b.top3 += 1 }
        if let f = first1 {
            b.top1 += 1
            b.top1Left.append(f)
            b.lettersSaved += f   // the rest of the word and the space, for the one tap
        }
        bands[band(n)] = b
    }
    let seconds = Date().timeIntervalSince(started)
    var json: [String: Any] = [
        "name": name, "words": export.words.count, "ms_per_word": 1000 * seconds / Double(max(export.words.count, 1)),
        "autocorrect": ["clean": auto.clean, "breaks": auto.broke, "typos_left_fixed": auto.typosLeftFixed,
                        "user_fixed": auto.fixedWords, "made_right": auto.madeRight, "made_wrong": auto.madeWrong],
        "post": ["looked": post.looked, "fixed": post.fixed, "breaks": post.broke],
        "prediction": ["words": predicted.words, "top3": predicted.top3, "top1": predicted.top1],
        "decoder": ["words": accuracy.words, "top1": accuracy.top1, "top3": accuracy.top3, "literal_right": accuracy.literalRight,
                    "top1_pct": accuracy.words > 0 ? 100 * Double(accuracy.top1) / Double(accuracy.words) : 0],
    ]
    var suggestions: [String: Any] = [:]
    var saved = 0, letters = 0
    for (key, b) in bands {
        saved += b.lettersSaved
        letters += b.letters
        let left = b.top1Left.sorted()
        suggestions[key] = ["words": b.words, "top3": b.top3, "top1": b.top1, "letters_saved": b.lettersSaved,
                            "top1_left_median": left.isEmpty ? 0 : left[left.count / 2]]
    }
    suggestions["keystrokes_saved_pct"] = letters > 0 ? 100 * Double(saved) / Double(letters) : 0
    json["suggestions"] = suggestions
    let dir = URL(fileURLWithPath: "build/bench", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("\(name).json"))
    print(String(data: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    exit(0)
}

// `--at-letters <k>`: the decoder's suggestions with only the first k letters typed, for words of
// four letters or more the lexicon has — first and in the top three, to set against a model's.
if let i = args.firstIndex(of: "--at-letters"), i + 1 < args.count, let k = Int(args[i + 1]) {
    var n = 0, first = 0, three = 0
    // `--recent <n>`: the last n words typed before, lifted as the keyboard lifts its recent words.
    let recentCount = args.firstIndex(of: "--recent").flatMap { j in j + 1 < args.count ? Int(args[j + 1]) : nil } ?? 0
    if let j = args.firstIndex(of: "--recent-lift"), j + 1 < args.count, let l = Int(args[j + 1]) { decoder.recentLift = l }
    var typed: [Int] = []
    for word in export.words {
        defer { if let node = lexicon.lookup(word.truth.lowercased()) { typed.append(node) } }
        guard word.kind == "clean", word.taps.count >= max(4, k + 1) else { continue }
        let truth = word.truth.lowercased()
        guard lexicon.lookup(truth) != nil, truth.count == word.taps.count else { continue }
        let taps = word.taps.prefix(k).map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        if recentCount > 0 { context.recent = Set(typed.suffix(recentCount)) }
        var shown: [String] = []
        for c in decoder.decode(Array(taps), complete: true, context: context).candidates where !shown.contains(c.word.lowercased()) {
            shown.append(c.word.lowercased())
            if shown.count == 3 { break }
        }
        n += 1
        if shown.first == truth { first += 1 }
        if shown.contains(truth) { three += 1 }
    }
    print("decoder with \(k) letters: \(n) words, first \(first) (\(100 * first / max(n, 1))%), in three \(three) (\(100 * three / max(n, 1))%)")
    exit(0)
}

// `--post`: the previous word looked at again once the next is typed — the decoder's candidates
// rescored with how likely each is right before the next word (the bigram's lift, as the left
// context lifts it), changed only when the word wasn't one or the decoder doubted it. Counted:
// words it would put right and words it would make wrong, typing fast and slowly apart.
if args.contains("--post"), let bigrams {
    var counts: [String: (fixed: Int, broken: Int, words: Int)] = [:]
    var shown: [String] = []
    let minLift = args.firstIndex(of: "--min-lift").flatMap { i in i + 1 < args.count ? Int(args[i + 1]) : nil } ?? 4
    for word in export.words where word.taps.count >= 2 {
        guard let next = word.next, let nextNode = lexicon.lookup(next.lowercased()) else { continue }
        let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous) }
        let result = decoder.decode(taps, context: context)
        let typed = word.taps.map(\.char).joined().lowercased()
        let live = (result.correction ?? result.literal).lowercased()
        let truth = word.truth.lowercased()
        let mode = word.fast == true ? "fast" : "slow"
        counts[mode, default: (0, 0, 0)].words += 1
        // Only a word the decoder left unsure: no word as typed, or a correction it nearly made.
        guard !result.literalIsWord || result.confidence > decoder.threshold * 0.5 else { continue }
        func rightLift(_ w: String) -> Int { lexicon.lookup(w).map { bigrams.weight(of: nextNode, after: $0) } ?? 0 }
        let rescored = result.candidates.prefix(5).map { c -> (String, Float, Int) in
            let lift = rightLift(c.word.lowercased())
            let f = Float(c.frequency)
            let lifted = lift > 0 ? f + Float(lift + 1) * (255 - f) / 16.5 : f
            return (c.word.lowercased(), c.cost - decoder.costs.language * (min(lifted, 255) - f) / 255, lift)
        }.sorted { $0.1 < $1.1 }
        guard let best = rescored.first, best.0 != live, best.2 >= minLift else { continue }
        if best.0 == truth && live != truth {
            counts[mode]!.fixed += 1
            shown.append("  FIXES  [\(mode)] \(typed) → \(best.0)  (live: \(live); before «\(next)»)")
        } else if live == truth && best.0 != truth {
            counts[mode]!.broken += 1
            shown.append("  BREAKS [\(mode)] \(typed) → \(best.0)  (live had it right; before «\(next)»)")
        }
    }
    for (mode, c) in counts.sorted(by: { $0.key < $1.key }) {
        print("\(mode): \(c.words) words with a next word — the second look would put right \(c.fixed), make wrong \(c.broken)")
    }
    shown.forEach { print($0) }
    exit(0)
}

var cleanTotal = 0, falseCorrections = 0, cleanTop = 0, typosLeft = 0
var fixedTotal = 0, fixedRight = 0, fixedWrong = 0, fixedTop3 = 0
var seconds = 0.0
var lines: [String] = []
for word in export.words where word.taps.count >= 2 {
    let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
    let started = Date()
    var context = WordDecoder.Context()
    if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous) }
    let result = decoder.decode(taps, context: context)
    seconds += Date().timeIntervalSince(started)
    let truth = word.truth.lowercased()
    let typed = word.taps.map(\.char).joined()
    let top3 = result.candidates.prefix(3).map { $0.word.lowercased() }
    if word.kind == "clean" {
        cleanTotal += 1
        if result.candidates.first?.word.lowercased() == truth { cleanTop += 1 }
        if let c = result.correction, c.lowercased() != truth {
            if word.typed_is_word ?? true {
                falseCorrections += 1
                lines.append("  BREAKS  \(typed) → \(c)  (\(String(format: "%.3f", result.confidence)))")
            } else {
                typosLeft += 1
                lines.append("  FIXES   \(typed) → \(c)  (a typo left in; \(String(format: "%.3f", result.confidence)))")
            }
        }
    } else {
        fixedTotal += 1
        if top3.contains(truth) { fixedTop3 += 1 }
        if result.correction?.lowercased() == truth {
            fixedRight += 1
            lines.append("  FIXES   \(typed) → \(word.truth)  (\(String(format: "%.3f", result.confidence)))")
        } else if let c = result.correction {
            fixedWrong += 1
            lines.append("  WRONG   \(typed) → \(c), meant \(word.truth)")
        } else if verbose {
            lines.append("  misses  \(typed) (meant \(word.truth)); top: \(top3.joined(separator: ", ")) conf \(String(format: "%.3f", result.confidence))")
        }
    }
}
print("words left as typed: \(cleanTotal) — the decoder would break \(falseCorrections) real words (\(String(format: "%.1f", 100 * Double(falseCorrections) / Double(max(cleanTotal, 1))))%) and fix \(typosLeft) typos left in; its top pick is the word in \(cleanTop)")
print("words the user put right: \(fixedTotal) — it'd fix \(fixedRight), change \(fixedWrong) wrongly; the word is in its top 3 for \(fixedTop3)")
print("time: \(String(format: "%.2f", 1000 * seconds / Double(max(cleanTotal + fixedTotal, 1)))) ms a word")
lines.forEach { print($0) }
