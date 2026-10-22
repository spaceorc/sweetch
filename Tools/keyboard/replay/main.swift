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
        let previous2: String?; let previous2_start: Bool?
        /// The Mac's: when the word's first and last keys came, and its go of typing.
        let t0: Double?; let t1: Double?; let session: Int?
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
// The predictions from NextWords.bin beside the lexicon, unless `--no-next-words` (the bigrams').
if !args.contains("--no-next-words") {
    decoder.nextWords = NextWords(url: URL(fileURLWithPath: args[1]).deletingLastPathComponent().appendingPathComponent("NextWords.bin"))
}
if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let t = Float(args[i + 1]) { decoder.threshold = t }
if args.contains("--by-confidence") { decoder.byConfidence = true }
if let i = args.firstIndex(of: "--language"), i + 1 < args.count, let l = Float(args[i + 1]) { decoder.costs.language = l }
if let i = args.firstIndex(of: "--substitution"), i + 1 < args.count, let v = Float(args[i + 1]) { decoder.costs.substitution = v }
if let i = args.firstIndex(of: "--distance"), i + 1 < args.count, let v = Float(args[i + 1]) { decoder.costs.distance = v }
if let i = args.firstIndex(of: "--next-word-limit"), i + 1 < args.count, let v = Int(args[i + 1]) { decoder.nextWordLimit = v }
if let i = args.firstIndex(of: "--next-word-scale"), i + 1 < args.count, let v = Float(args[i + 1]) { decoder.nextWordScale = v }
if let i = args.firstIndex(of: "--beam"), i + 1 < args.count, let v = Int(args[i + 1]) { decoder.costs.beam = v }

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
        guard word.taps.count >= 2, !word.kind.hasPrefix("layout") else { continue }   // the Mac's: see --layouts
        let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        if recentCount > 0 { context.recent = Set(typedSoFar.suffix(recentCount)) }
        if word.previous2_start == true { context.previous2 = 0 } else if let p2 = word.previous2 { context.previous2 = lexicon.lookup(p2.lowercased()) }
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
            // `--from-two`: as before 22 Oct — the decoder's own, from the second letter.
            let fromTwo = args.contains("--from-two")
            for k in (fromTwo ? 2 : 1)..<n {
                let shown = fromTwo
                    ? Array(decoder.decode(Array(taps.prefix(k)), complete: true, context: context).candidates.map { $0.word.lowercased() }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(3))
                    : decoder.completions(Array(taps.prefix(k)), context: context).map { $0.lowercased() }
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
        if word.previous2_start == true { context.previous2 = 0 } else if let p2 = word.previous2 { context.previous2 = lexicon.lookup(p2.lowercased()) }
        if recentCount > 0 { context.recent = Set(typed.suffix(recentCount)) }
        let shown = decoder.completions(Array(taps), context: context).map { $0.lowercased() }
        n += 1
        if shown.first == truth { first += 1 }
        if shown.contains(truth) { three += 1 }
    }
    print("decoder with \(k) letters: \(n) words, first \(first) (\(100 * first / max(n, 1))%), in three \(three) (\(100 * three / max(n, 1))%)")
    exit(0)
}

// `--alternatives [<gap>]`: after a word ends, the strip could offer the decoder's runners-up — the
// candidates within `gap` of the best's cost, other than what went in and what was typed, two at
// most. Counted: words that went in wrong (a correction the user undid or a typo they put right
// themselves) whose word was among them; and how often any were shown on a word that went in right
// (where the next-word predictions would have been).
if let i = args.firstIndex(of: "--alternatives") {
    let gap = i + 1 < args.count ? Float(args[i + 1]) ?? 0.3 : 0.3
    var wrong = (corrected: 0, correctedHelped: 0, left: 0, leftHelped: 0, broke: 0)
    var right = (words: 0, shown: 0)
    var gaps: [Float] = []
    var found = 0, unknown = 0, droppedFinds = 0
    var shownLines: [String] = []
    for word in export.words where word.taps.count >= 2 {
        let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        let result = decoder.decode(taps, context: context)
        let truth = word.truth.lowercased(), typed = word.taps.map(\.char).joined().lowercased()
        let live = (result.correction ?? result.literal).lowercased()
        guard let best = result.candidates.first?.cost else { continue }
        var alternatives: [(String, Float)] = []
        for c in result.candidates {
            let w = c.word.lowercased()
            guard w != live, w != typed, !alternatives.contains(where: { $0.0 == w }) else { continue }
            alternatives.append((w, c.cost - best))
            if alternatives.count == 2 { break }
        }
        let near = alternatives.filter { $0.1 <= gap }
        // A typo the user left in, put right: as good as right.
        if live == truth || (word.kind == "clean" && result.correction != nil && !(word.typed_is_word ?? true)) {
            right.words += 1
            if !near.isEmpty { right.shown += 1 }
            continue
        }
        if result.correction != nil, typed == truth {
            wrong.broke += 1
            if verbose { shownLines.append("  BROKE \(typed) → \(live) [\(word.kind)]") }
            continue   // the undo covers it
        }
        if result.candidates.contains(where: { $0.word.lowercased() == truth }) { found += 1 } else if lexicon.lookup(truth) == nil { unknown += 1 } else if taps.count >= 3 {
            // Not found: would it be, with one tap taken out (struck by accident)?
            var best: (String, Float)?
            for drop in taps.indices {
                var fewer = taps
                fewer.remove(at: drop)
                if let c = decoder.decode(fewer, context: context).candidates.first, best == nil || c.cost < best!.1 { best = (c.word.lowercased(), c.cost) }
            }
            if best?.0 == truth { droppedFinds += 1 }
            if verbose { shownLines.append("  DROP  \(typed), meant \(truth): one tap out gives \(best?.0 ?? "-")") }
        }
        let at = alternatives.first { $0.0 == truth }
        if let at { gaps.append(at.1) }
        let helped = near.contains { $0.0 == truth }
        if result.correction != nil {
            wrong.corrected += 1
            if helped { wrong.correctedHelped += 1 }
        } else {
            wrong.left += 1
            if helped { wrong.leftHelped += 1 }
        }
        if helped || verbose {
            shownLines.append("  \(helped ? "HELPS" : "     ") \(typed) → \(live), meant \(truth); offered \(alternatives.map { "\($0.0) +\(String(format: "%.2f", $0.1))" }.joined(separator: ", "))")
        }
    }
    print("gap \(gap): words that went in right \(right.words), runners-up shown on \(right.shown) (\(100 * right.shown / max(right.words, 1))%)")
    print("went in wrong: corrected wrongly \(wrong.corrected) — the word offered for \(wrong.correctedHelped); typo left \(wrong.left) — offered for \(wrong.leftHelped); a real word corrected away \(wrong.broke) (the undo)")
    print("the meant word among all the candidates: \(found) of \(wrong.corrected + wrong.left); not in the lexicon: \(unknown); found with one tap taken out: \(droppedFinds)")
    print("the meant word's gap when among the two: \(gaps.sorted().map { String(format: "%.2f", $0) }.joined(separator: " "))")
    shownLines.forEach { print($0) }
    exit(0)
}

// `--predict-texts <texts.json>`: the next-word predictions on sentences the user wrote (a JSON
// list of texts) — before each word, from the one or two before it: how often it's first, and in
// the three. On held-out texts (a lexicon built SWEETCH_UNTIL their day) it's the honest measure.
if let i = args.firstIndex(of: "--predict-texts"), i + 1 < args.count {
    let texts = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: args[i + 1])))
    let token = try NSRegularExpression(pattern: "[A-Za-zА-Яа-яЁё]+(?:[-'’][A-Za-zА-Яа-яЁё]+)*")
    var n = 0, first = 0, three = 0
    // `--dump <file.json>`: each word with the one before and the three shown, for a closer look.
    let dumpPath = args.firstIndex(of: "--dump").flatMap { j in j + 1 < args.count ? args[j + 1] : nil }
    var dump: [[String: Any]]? = dumpPath == nil ? nil : []
    for text in texts {
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?…\n")) {
            let ns = sentence as NSString
            let words = token.matches(in: sentence, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() }
            var previous2: Int?, previous: Int? = 0
            for word in words {
                let node = lexicon.lookup(word)
                if let node, let p = previous {
                    var context = WordDecoder.Context()
                    context.previous = p
                    context.previous2 = previous2
                    let shown = decoder.predictions(context).map { $0.lowercased() }
                    if dump != nil { dump!.append(["previous": lexicon.word(at: p).lowercased(), "word": word, "shown": shown]) }
                    n += 1
                    if shown.first == word { first += 1 }
                    if shown.contains(word) { three += 1 }
                }
                previous2 = previous
                previous = node
            }
        }
    }
    if let dumpPath, let dump { try JSONSerialization.data(withJSONObject: dump).write(to: URL(fileURLWithPath: dumpPath)) }
    print("\(n) words: first \(first) (\(String(format: "%.1f", 100 * Double(first) / Double(max(n, 1))))%), in three \(three) (\(String(format: "%.1f", 100 * Double(three) / Double(max(n, 1))))%)")
    exit(0)
}

// `--layouts [<min frequency>] [<min letters>]`: a word typed in the wrong layout (the Mac's export,
// export_mac_words.py), switched as it ends: when the keys make no word in the layout they were typed
// in, and in the other they make one at least that common, that long. Counted: the wrong-layout
// words it puts right (the user's own fixes, and those left as typed), and the real words it breaks.
if let i = args.firstIndex(of: "--layouts") {
    let minFrequency = i + 1 < args.count ? Int(args[i + 1]) ?? 0 : 0
    let minLetters = i + 2 < args.count ? Int(args[i + 2]) ?? 2 : 2
    // `--margin <m>`: switched too when the keys make a word in both, the other's that much commoner.
    let margin = args.firstIndex(of: "--margin").flatMap { j in j + 1 < args.count ? Int(args[j + 1]) : nil } ?? 1000
    var counts: [String: (n: Int, switched: Int, right: Int)] = [:]
    var lines: [String] = []
    for word in export.words where word.taps.count >= 2 {
        let own = word.taps[0].layout
        guard let other = keys.keys.first(where: { $0 != own }), let otherKeys = keys[other] else { continue }
        let mine = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[own] ?? [], deliberate: $0.deliberate) }
        let theirs = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: otherKeys, deliberate: $0.deliberate) }
        let typed = word.taps.map(\.char).joined().lowercased(), truth = word.truth.lowercased()
        let mineResult = decoder.decode(mine), theirsResult = decoder.decode(theirs)
        let converted = theirsResult.literal.lowercased()
        let frequency = lexicon.lookup(converted).map { Int(lexicon.frequency($0)) } ?? 0
        let mineFrequency = lexicon.lookup(mineResult.literal.lowercased()).map { Int(lexicon.frequency($0)) } ?? 0
        let switched = typed.count >= minLetters && (!mineResult.literalIsWord || mineFrequency + margin <= frequency)
            && theirsResult.literalIsWord && frequency >= minFrequency
        let kind = word.kind == "clean" ? (word.typed_is_word == true ? "clean, a word" : "clean, no word") : word.kind
        var c = counts[kind] ?? (0, 0, 0)
        c.n += 1
        if switched {
            c.switched += 1
            if converted == truth { c.right += 1 }
            if kind == "clean, a word" || verbose { lines.append("  \(kind == "clean, a word" ? "BREAKS" : "      ") [\(kind)] \(typed) → \(converted) (\(frequency))") }
        } else if kind.hasPrefix("layout"), verbose {
            lines.append("  misses [\(kind)] \(typed) (meant \(truth); \(converted) \(frequency), mine a word: \(mineResult.literalIsWord))")
        }
        counts[kind] = c
    }
    print("min frequency \(minFrequency), min letters \(minLetters):")
    for (kind, c) in counts.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(c.n) — switched \(c.switched), to the word meant \(c.right)") }
    lines.forEach { print($0) }
    exit(0)
}

// `--layout-runs [<min frequency> <min letters> <margin> <gap>]`: the Mac's switching of the layout
// replayed in order, word by word as typed: a word plainly in the wrong layout switched as it ends
// (as --layouts), and with it — rule B — the words of the same go just before it (keys no more than
// `gap` seconds apart, the same layout, not switched already) that the other layout suits no
// worse; rule A switches the word alone. Counted for both, as --layouts.
if let i = args.firstIndex(of: "--layout-runs") {
    let n = { (k: Int, d: Double) in i + k < args.count ? Double(args[i + k]) ?? d : d }
    let minFrequency = Int(n(1, 100)), minLetters = Int(n(2, 2)), margin = Int(n(3, 120)), gap = n(4, 2)
    struct Seen { let word: Export.Word; let typed: String; let converted: String; let own: Int; let other: Int; let layout: String }
    func frequency(_ w: String) -> Int { lexicon.lookup(w).map { Int(lexicon.frequency($0)) } ?? 0 }
    var seen: [Seen] = []
    for word in export.words where word.taps.count >= 1 {
        let own = word.taps[0].layout
        guard let other = keys.keys.first(where: { $0 != own }), let otherKeys = keys[other] else { continue }
        let mine = decoder.decode(word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[own] ?? [], deliberate: false) })
        let theirs = decoder.decode(word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: otherKeys, deliberate: false) })
        let typed = mine.literal.lowercased(), converted = theirs.literal.lowercased()
        seen.append(Seen(word: word, typed: typed, converted: converted, own: frequency(typed), other: frequency(converted), layout: own))
    }
    for rule in ["A", "B"] {
        var switched = Set<Int>()
        var extra: [String] = []
        for (j, w) in seen.enumerated() {
            let plainly = w.typed.count >= minLetters && w.other >= minFrequency && (w.own == 0 || w.own + margin <= w.other)
            guard plainly else { continue }
            switched.insert(j)
            guard rule == "B" else { continue }
            var k = j
            while k > 0 {
                let p = seen[k - 1], next = seen[k]
                guard p.word.session == w.word.session, let t1 = p.word.t1, let t0 = next.word.t0, t0 - t1 <= gap,
                      !switched.contains(k - 1), p.layout == w.layout, p.other > 0, p.other >= p.own else { break }
                switched.insert(k - 1)
                extra.append("  \(p.word.kind == "clean" && p.word.typed_is_word == true ? "BREAKS" : "      ") [\(p.word.kind)] \(p.typed) → \(p.converted) (before \(w.typed) → \(w.converted))")
                k -= 1
            }
        }
        var counts: [String: (n: Int, switched: Int, right: Int)] = [:]
        for (j, w) in seen.enumerated() {
            let kind = w.word.kind == "clean" ? (w.word.typed_is_word == true ? "clean, a word" : "clean, no word") : w.word.kind
            var c = counts[kind] ?? (0, 0, 0)
            c.n += 1
            if switched.contains(j) { c.switched += 1; if w.converted == w.word.truth.lowercased() { c.right += 1 } }
            counts[kind] = c
        }
        print("rule \(rule) (\(rule == "A" ? "the word alone" : "with the go before it")):")
        for (kind, c) in counts.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(c.n) — switched \(c.switched), to the word meant \(c.right)") }
        if rule == "B", verbose { extra.forEach { print($0) } }
    }
    exit(0)
}

// `--fixes`: a word gone back to and put right — the decoder's first three for it (and the best
// with a tap taken out, when short of three), from the taps that typed it and from taps made up in
// the middle of each letter's key, as the keyboard does when it doesn't remember them.
if args.contains("--fixes") {
    var n = 0, real = 0, made = 0
    for word in export.words where word.taps.count >= 2 && word.kind != "clean" {
        let truth = word.truth.lowercased(), typed = word.taps.map(\.char).joined().lowercased()
        guard typed != truth else { continue }
        let layout = word.taps[0].layout
        let lk = keys[layout] ?? []
        let realTaps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: lk, deliberate: $0.deliberate) }
        let madeTaps = typed.compactMap { ch in lk.first { $0.letter == ch }.map { WordDecoder.Tap(point: CGPoint(x: $0.frame.midX, y: $0.frame.midY), keys: lk, deliberate: false) } }
        guard madeTaps.count == realTaps.count else { continue }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        func offered(_ taps: [WordDecoder.Tap]) -> [String] {
            var found: [String] = []
            for c in decoder.decode(taps, context: context).candidates where c.word.lowercased() != typed && !found.contains(c.word.lowercased()) && found.count < 3 { found.append(c.word.lowercased()) }
            if found.count < 3, taps.count >= 3 {
                var best: (String, Float)?
                for d in taps.indices { var f = taps; f.remove(at: d); if let c = decoder.decode(f, context: context).candidates.first, best == nil || c.cost < best!.1 { best = (c.word.lowercased(), c.cost) } }
                if let best, !found.contains(best.0), best.0 != typed { found.append(best.0) }
            }
            return found
        }
        n += 1
        let r = offered(realTaps), m = offered(madeTaps)
        if r.contains(truth) { real += 1 }
        if m.contains(truth) { made += 1 }
        if verbose { print("  \(typed) meant \(truth): taps \(r.contains(truth) ? "+" : "-") \(r)  made-up \(m.contains(truth) ? "+" : "-") \(m)") }
    }
    print("words put right by hand: \(n) — the word among the three from the taps \(real), from made-up taps \(made)")
    exit(0)
}

// `--drop-one <penalty> [<gap>]`: the word decoded again with each tap taken out in turn (one
// struck by accident), its best offered when within `gap` of the decoder's best once `penalty` is
// added. Counted: the word meant offered where what went in was wrong, and offers on words that
// went in right.
if let i = args.firstIndex(of: "--drop-one"), i + 1 < args.count, let penalty = Float(args[i + 1]) {
    let gap = i + 2 < args.count ? Float(args[i + 2]) ?? 0.1 : 0.1
    var helped = 0, wrongs = 0, noise = 0, rights = 0
    var lines: [String] = []
    for word in export.words where word.taps.count >= 3 {
        let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
        var context = WordDecoder.Context()
        if word.sentence_start == true { context.previous = 0 } else if let previous = word.previous { context.previous = lexicon.lookup(previous.lowercased()) }
        let result = decoder.decode(taps, context: context)
        let truth = word.truth.lowercased(), typed = word.taps.map(\.char).joined().lowercased()
        let live = (result.correction ?? result.literal).lowercased()
        guard let best = result.candidates.first?.cost else { continue }
        var offer: (String, Float)?
        for drop in taps.indices {
            var fewer = taps
            fewer.remove(at: drop)
            for c in decoder.decode(fewer, context: context).candidates.prefix(1) {
                let w = c.word.lowercased()
                guard w != live, w != typed, c.cost + penalty - best <= gap else { continue }
                if offer == nil || c.cost < offer!.1 { offer = (w, c.cost) }
            }
        }
        let wentRight = live == truth || (word.kind == "clean" && result.correction != nil && !(word.typed_is_word ?? true))
        if wentRight {
            rights += 1
            if let offer { noise += 1; if verbose { lines.append("  NOISE \(typed) → \(live); offers \(offer.0)") } }
        } else if !(result.correction != nil && typed == truth) {
            wrongs += 1
            if offer?.0 == truth { helped += 1; lines.append("  HELPS \(typed) → \(live), meant \(truth)") }
        }
    }
    print("penalty \(penalty) gap \(gap): the word meant offered for \(helped) of \(wrongs) gone in wrong; offers on \(noise) of \(rights) gone in right")
    lines.forEach { print($0) }
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
    // `--explain <typed>`: the candidates for that word and what each cost.
    if let i = args.firstIndex(of: "--explain"), i + 1 < args.count, word.taps.map(\.char).joined() == args[i + 1] {
        print("\(args[i + 1]) → \(result.correction ?? "(left)") conf \(String(format: "%.3f", result.confidence))")
        for c in result.candidates.prefix(6) { print("   \(c.word): cost \(String(format: "%.3f", c.cost)), edits \(c.edits), frequency \(c.frequency)") }
    }
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
            if verbose {
                for cand in result.candidates.prefix(5) {
                    lines.append("            \(cand.word): cost \(String(format: "%.2f", cand.cost)), edits \(cand.edits), frequency \(cand.frequency)")
                }
            }
        } else if verbose {
            lines.append("  misses  \(typed) (meant \(word.truth)); top: \(top3.joined(separator: ", ")) conf \(String(format: "%.3f", result.confidence))")
        }
    }
}
print("words left as typed: \(cleanTotal) — the decoder would break \(falseCorrections) real words (\(String(format: "%.1f", 100 * Double(falseCorrections) / Double(max(cleanTotal, 1))))%) and fix \(typosLeft) typos left in; its top pick is the word in \(cleanTop)")
print("words the user put right: \(fixedTotal) — it'd fix \(fixedRight), change \(fixedWrong) wrongly; the word is in its top 3 for \(fixedTop3)")
print("time: \(String(format: "%.2f", 1000 * seconds / Double(max(cleanTotal + fixedTotal, 1)))) ms a word")
lines.forEach { print($0) }
