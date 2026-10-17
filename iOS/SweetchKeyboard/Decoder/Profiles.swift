import Foundation

/// The user's three ways of writing — personal, work, to an agent — as Tools/keyboard/build_lexicon.py
/// counts them on the Mac: for each, how much likelier or rarer each of the user's words is there
/// than across all their writing (−8…8), and the profile's own word pairs (0–15). Words are lexicon
/// node ids. Read whole: it's small.
final class Profiles {
    enum Name: Int, CaseIterable {
        case personal, work, agent

        var key: String { ["personal", "work", "agent"][rawValue] }
    }

    private var weights: [[Int: Int8]] = []
    private var pairs: [[Int: [Int: UInt8]]] = []

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 12,
              data.prefix(4) == Data("SWPF".utf8) else { return nil }
        var at = 4
        func u32() -> Int {
            defer { at += 4 }
            return Int(UInt32(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }))
        }
        guard u32() == 1 else { return nil }
        let count = u32()
        for _ in 0..<count {
            let n = u32()
            let words = (0..<n).map { _ in u32() }
            var table: [Int: Int8] = [:]
            for (i, word) in words.enumerated() { table[word] = Int8(bitPattern: data[data.startIndex + at + i]) }
            at += n
            weights.append(table)
            let m = u32()
            let previous = (0..<m).map { _ in u32() }
            let next = (0..<m).map { _ in u32() }
            var byPrevious: [Int: [Int: UInt8]] = [:]
            for i in 0..<m { byPrevious[previous[i], default: [:]][next[i]] = data[data.startIndex + at + i] }
            at += m
            pairs.append(byPrevious)
        }
    }

    /// −8…8: how much likelier `word` is in `profile` than in the user's writing at large.
    func weight(of word: Int, in profile: Name) -> Int {
        guard profile.rawValue < weights.count else { return 0 }
        return Int(weights[profile.rawValue][word] ?? 0)
    }

    /// 0–15: how much likelier `word` is after `previous` in `profile`.
    func pair(_ word: Int, after previous: Int, in profile: Name) -> Int {
        guard profile.rawValue < pairs.count else { return 0 }
        return Int(pairs[profile.rawValue][previous]?[word] ?? 0)
    }

    /// The profile's likeliest next words after `previous`.
    func next(after previous: Int, in profile: Name, limit: Int) -> [Int] {
        guard profile.rawValue < pairs.count, let after = pairs[profile.rawValue][previous] else { return [] }
        return after.sorted { $0.value > $1.value }.prefix(limit).map(\.key)
    }
}
