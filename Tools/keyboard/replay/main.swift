import CoreGraphics
import Foundation

// The decoder (iOS/SweetchKeyboard/Decoder) run on the words typed on the keyboard
// (Tools/keyboard/export_words.py): on the words left as typed it must change nothing; on the ones
// the user put right it should find what they meant.
//
// Usage: replay <Lexicon.bin> <words.json> [--verbose]

struct Export: Decodable {
    struct Tap: Decodable { let char: String; let x: Double; let y: Double; let layout: String; let deliberate: Bool }
    struct Word: Decodable { let kind: String; let taps: [Tap]; let truth: String; let typed_is_word: Bool? }
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
let keys: [String: [WordDecoder.Key]] = export.layouts.mapValues { rows in
    rows.map { WordDecoder.Key(letter: Character($0[0].text), frame: CGRect(x: $0[1].number, y: $0[2].number, width: $0[3].number, height: $0[4].number)) }
}
let decoder = WordDecoder(lexicon: lexicon)
if let i = args.firstIndex(of: "--threshold"), i + 1 < args.count, let t = Float(args[i + 1]) { decoder.threshold = t }

var cleanTotal = 0, falseCorrections = 0, cleanTop = 0, typosLeft = 0
var fixedTotal = 0, fixedRight = 0, fixedWrong = 0, fixedTop3 = 0
var seconds = 0.0
var lines: [String] = []
for word in export.words where word.taps.count >= 2 {
    let taps = word.taps.map { WordDecoder.Tap(point: CGPoint(x: $0.x, y: $0.y), keys: keys[$0.layout] ?? [], deliberate: $0.deliberate) }
    let started = Date()
    let result = decoder.decode(taps)
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
