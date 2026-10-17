import Foundation

/// How much likelier a word is after another (Tools/keyboard/build_lexicon.py writes them): from
/// the user's own sentences and the general lists' likeliest next words. Words are their lexicon
/// node ids; 0, the root, is a sentence's start. Memory-mapped, like the lexicon.
final class Bigrams {
    private let base: UnsafeRawPointer
    private let size: Int
    let count: Int
    private let previousOffset, wordOffset, weightOffset: Int

    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 12 else { return nil }
        size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else { return nil }
        let p = UnsafeRawPointer(mapped)
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        guard String(decoding: UnsafeRawBufferPointer(start: p, count: 4), as: UTF8.self) == "SWBG", u32(4) == 1 else {
            munmap(mapped, size)
            return nil
        }
        count = u32(8)
        previousOffset = 12
        wordOffset = previousOffset + 4 * count
        weightOffset = wordOffset + 4 * count
        base = p
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    @inline(__always) private func previous(_ i: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: previousOffset + 4 * i, as: UInt32.self)))
    }
    @inline(__always) private func word(_ i: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: wordOffset + 4 * i, as: UInt32.self)))
    }
    @inline(__always) private func weight(_ i: Int) -> Int { Int(base.load(fromByteOffset: weightOffset + i, as: UInt8.self)) }

    /// The pairs that start with `previous`.
    private func range(after previous: Int) -> Range<Int> {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if self.previous(mid) < previous { low = mid + 1 } else { high = mid }
        }
        var end = low
        while end < count, self.previous(end) == previous { end += 1 }
        return low..<end
    }

    /// 0–15: how much likelier `word` is after `previous`; 0 when the pair was never seen.
    func weight(of word: Int, after previous: Int) -> Int {
        var range = range(after: previous)
        while !range.isEmpty {
            let mid = range.lowerBound + range.count / 2
            let here = self.word(mid)
            if here == word { return weight(mid) }
            if here < word { range = mid + 1..<range.upperBound } else { range = range.lowerBound..<mid }
        }
        return 0
    }

    /// The words seen after `previous`, heaviest first.
    func next(after previous: Int, limit: Int) -> [(word: Int, weight: Int)] {
        let found: [(word: Int, weight: Int)] = range(after: previous).map { (word: word($0), weight: weight($0)) }
        return Array(found.sorted { $0.weight > $1.weight }.prefix(limit))
    }
}
