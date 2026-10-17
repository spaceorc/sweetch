import UIKit

/// The field's lines as iOS would lay them out — a keyboard is told the text around the cursor,
/// never where the field wraps it. Each paragraph is wrapped by words at a width, measured in the
/// system's body font at the user's text size; the cursor goes up and down to the same distance
/// from the line's start, in points, as iOS's own keyboard does.
///
/// The field's width (and so where it wraps) isn't known either: it is learned from how the user
/// finishes a move — a line up, then a nudge sideways to where they meant — per app (its process,
/// all a keyboard can tell of it) and across apps.
struct TextLines {
    let text: [Character]
    let lines: [Range<Int>]
    private let font: UIFont

    init(_ text: String, width: CGFloat, font: UIFont) {
        self.text = Array(text)
        self.font = font
        lines = Self.wrap(self.text, width: width, font: font)
    }

    /// Where the cursor at `index` goes `count` lines down (negative: up), keeping its distance
    /// from the line's start; the first or last line's end when there's no line further.
    func move(_ index: Int, lines count: Int) -> Int {
        guard let current = line(of: index) else { return index }
        let x = width(lines[current].lowerBound..<min(index, lines[current].upperBound))
        let target = current + count
        guard target >= 0 else { return 0 }
        guard target < lines.count else { return text.count }
        let range = lines[target]
        // The character boundary in the target line nearest to x; a line's trailing space or break
        // isn't a place to stop.
        var end = range.upperBound
        while end > range.lowerBound, text[end - 1] == "\n" { end -= 1 }
        var best = range.lowerBound, bestGap = CGFloat.infinity, run: CGFloat = 0
        for i in range.lowerBound...end {
            let gap = abs(run - x)
            if gap < bestGap { best = i; bestGap = gap }
            if i < end { run += width(i..<i + 1) }
        }
        return best
    }

    private func line(of index: Int) -> Int? {
        if lines.isEmpty { return nil }
        // A cursor right at a wrap belongs to the line it starts.
        return lines.lastIndex { $0.lowerBound <= index } ?? 0
    }

    private func width(_ range: Range<Int>) -> CGFloat {
        guard !range.isEmpty else { return 0 }
        return (String(text[range]) as NSString).size(withAttributes: [.font: font]).width
    }

    /// Greedy wrapping by words, as UIKit does: a word that doesn't fit starts the next line, the
    /// spaces after a word hang at the end of its line, a word wider than the line is broken.
    private static func wrap(_ text: [Character], width: CGFloat, font: UIFont) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0, i = 0
        func measure(_ r: Range<Int>) -> CGFloat {
            (String(text[r]) as NSString).size(withAttributes: [.font: font]).width
        }
        while i <= text.count {
            if i == text.count || text[i] == "\n" {
                lines.append(contentsOf: wrapParagraph(start..<i, text: text, width: width, measure: measure))
                if i < text.count, let last = lines.indices.last { lines[last] = lines[last].lowerBound..<i + 1 }
                start = i + 1
                if i == text.count - 1 { lines.append(text.count..<text.count) }   // the empty line after a final break
            }
            i += 1
        }
        return lines.isEmpty ? [0..<0] : lines
    }

    private static func wrapParagraph(_ range: Range<Int>, text: [Character], width: CGFloat,
                                      measure: (Range<Int>) -> CGFloat) -> [Range<Int>] {
        if range.isEmpty { return [range] }
        var lines: [Range<Int>] = []
        var lineStart = range.lowerBound
        var i = range.lowerBound
        while i < range.upperBound {
            // The next word and the spaces after it.
            var wordEnd = i
            while wordEnd < range.upperBound, !text[wordEnd].isWhitespace { wordEnd += 1 }
            var spacesEnd = wordEnd
            while spacesEnd < range.upperBound, text[spacesEnd].isWhitespace { spacesEnd += 1 }
            if measure(lineStart..<wordEnd) <= width || lineStart == i {
                if lineStart == i, measure(i..<wordEnd) > width {
                    // A word wider than the line: as much as fits, the rest on the next.
                    var cut = i + 1
                    while cut < wordEnd, measure(i..<cut + 1) <= width { cut += 1 }
                    lines.append(lineStart..<cut)
                    lineStart = cut
                    i = cut
                    continue
                }
                i = spacesEnd
            } else {
                lines.append(lineStart..<i)
                lineStart = i
            }
        }
        lines.append(lineStart..<range.upperBound)
        return lines
    }
}

/// The field's width as learned from the user's moves: a move's start, how many lines it went,
/// and where the user settled after nudging sideways — the width that would have put the cursor
/// there is the field's. Kept per app process and across apps, on disk. Used only on `queue`.
final class FieldWidth: @unchecked Sendable {
    struct Move: Codable {
        let text: String
        let start: Int
        let lines: Int
        let settled: Int
    }

    static let shared = FieldWidth()
    /// Everything here runs on it: fitting wraps the text dozens of times.
    let queue = DispatchQueue(label: "sweetch.field-width", qos: .utility)
    private let key = "fieldWidthMoves"
    private var moves: [String: [Move]]   // by process ("pid:<n>") and "all"

    private init() {
        moves = (UserDefaults.standard.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([String: [Move]].self, from: $0) } ?? [:]
    }

    /// The width to wrap at for this app: its own moves' when it has a few, else all apps'.
    func width(for process: Int32?, font: UIFont, fallback: CGFloat) -> CGFloat {
        if let process, let own = moves["pid:\(process)"], own.count >= 2 {
            return fit(own, font: font, around: fallback)
        }
        if let all = moves["all"], all.count >= 2 { return fit(all, font: font, around: fallback) }
        return fallback
    }

    func learn(_ move: Move, process: Int32?, font: UIFont, fallback: CGFloat) -> CGFloat {
        for bucket in ["all"] + (process.map { ["pid:\($0)"] } ?? []) {
            moves[bucket, default: []].append(move)
            if moves[bucket]!.count > 40 { moves[bucket]!.removeFirst(moves[bucket]!.count - 40) }
        }
        // Processes come and go: keep the newest few.
        let pids = moves.keys.filter { $0.hasPrefix("pid:") }
        if pids.count > 12 { pids.prefix(pids.count - 12).forEach { moves[$0] = nil } }
        if let data = try? JSONEncoder().encode(moves) { UserDefaults.standard.set(data, forKey: key) }
        return width(for: process, font: font, fallback: fallback)
    }

    /// The width, from 200 to 480 pt, whose wrapping lands each move nearest where the user settled;
    /// of equals, the nearest to the guess.
    private func fit(_ moves: [Move], font: UIFont, around guess: CGFloat) -> CGFloat {
        var best = guess, bestMiss = Int.max
        for width in stride(from: CGFloat(200), through: 480, by: 4) {
            var miss = 0
            for move in moves {
                let lines = TextLines(move.text, width: width, font: font)
                miss += abs(lines.move(move.start, lines: move.lines) - move.settled)
            }
            if miss < bestMiss || (miss == bestMiss && abs(width - guess) < abs(best - guess)) {
                best = width
                bestMiss = miss
            }
        }
        return best
    }
}
