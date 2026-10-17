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
/// there is the field's. Kept per app process and across apps, on disk; worked out on `queue`,
/// read anywhere.
final class FieldWidth: @unchecked Sendable {
    struct Move: Codable {
        let text: String
        let start: Int
        let lines: Int
        let settled: Int
        var fontSize: CGFloat? = nil
    }

    static let shared = FieldWidth()
    /// Fitting wraps the text dozens of times: off the main thread.
    let queue = DispatchQueue(label: "sweetch.field-width", qos: .utility)
    /// A width is trusted once this many moves agree on it.
    static let enough = 3
    private let key = "fieldWidthMoves"
    private let lock = NSLock()
    private var moves: [String: [Move]] = [:]   // by process ("pid:<n>") and "all"
    private var fitted: [String: CGFloat] = [:]

    private init() {
        queue.async { [self] in
            let stored = UserDefaults.standard.data(forKey: key)
                .flatMap { try? JSONDecoder().decode([String: [Move]].self, from: $0) } ?? [:]
            let font = UIFont.preferredFont(forTextStyle: .body)
            var fits: [String: CGFloat] = [:]
            for (bucket, list) in stored where list.count >= Self.enough { fits[bucket] = fit(list, font: font, around: 400) }
            lock.withLock {
                moves = stored
                fitted = fits
            }
        }
    }

    /// The width to wrap at in this app: its own once it has enough moves, else all apps', else
    /// nil (the caller guesses).
    func width(for process: Int32?) -> CGFloat? {
        lock.withLock { process.flatMap { fitted["pid:\($0)"] } ?? fitted["all"] }
    }

    /// Call on `queue`. Returns the width it now makes of this app.
    func learn(_ move: Move, process: Int32?, font: UIFont, guess: CGFloat) -> CGFloat? {
        var all = lock.withLock { moves }
        let buckets = ["all"] + (process.map { ["pid:\($0)"] } ?? [])
        for bucket in buckets {
            all[bucket, default: []].append(move)
            if all[bucket]!.count > 40 { all[bucket]!.removeFirst(all[bucket]!.count - 40) }
        }
        // Processes come and go: keep the newest few.
        let pids = all.keys.filter { $0.hasPrefix("pid:") }.sorted()
        if pids.count > 12 { pids.prefix(pids.count - 12).forEach { all[$0] = nil } }
        var fits: [String: CGFloat] = [:]
        for bucket in buckets where all[bucket]!.count >= Self.enough {
            fits[bucket] = fit(all[bucket]!, font: font, around: guess)
        }
        lock.withLock {
            moves = all
            fitted.merge(fits) { $1 }
        }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
        return width(for: process)
    }

    /// The width, from 200 to 480 pt, that lands the most moves within a character of where the
    /// user settled — a move the user ended somewhere else on purpose then counts as one miss, not
    /// as its distance; of equals, the one nearer overall, then the one nearer the guess.
    private func fit(_ moves: [Move], font: UIFont, around guess: CGFloat) -> CGFloat {
        var best = guess, bestHits = -1, bestMiss = Int.max
        for width in stride(from: CGFloat(200), through: 480, by: 4) {
            var hits = 0, miss = 0
            for move in moves {
                let moveFont = move.fontSize.map { font.withSize($0) } ?? font
                let off = abs(TextLines(move.text, width: width, font: moveFont).move(move.start, lines: move.lines) - move.settled)
                if off <= 1 { hits += 1 }
                miss += off
            }
            if hits > bestHits || (hits == bestHits && (miss < bestMiss || (miss == bestMiss && abs(width - guess) < abs(best - guess)))) {
                best = width
                bestHits = hits
                bestMiss = miss
            }
        }
        return best
    }
}
