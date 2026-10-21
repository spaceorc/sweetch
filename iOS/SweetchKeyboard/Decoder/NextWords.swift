import Foundation

/// The likeliest next words after one word, or after two (Tools/keyboard/ngrams.py writes them):
/// word triples and pairs counted in the Leipzig corpora and the user's own texts, smoothed. Words
/// are lexicon node ids; 0, the root, is a sentence's start. Memory-mapped, like the lexicon.
final class NextWords {
    private let base: UnsafeRawPointer
    private let size: Int
    private let contexts: Int
    private let tableOffset, entriesOffset: Int
    private static let none = 0xFFFF_FFFF
    private static let row = 14

    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size >= 16 else { return nil }
        size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else { return nil }
        let p = UnsafeRawPointer(mapped)
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        guard String(decoding: UnsafeRawBufferPointer(start: p, count: 4), as: UTF8.self) == "SWNW", u32(4) == 1 else {
            munmap(mapped, size)
            return nil
        }
        contexts = u32(8)
        tableOffset = 16
        entriesOffset = tableOffset + Self.row * contexts
        base = p
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    @inline(__always) private func u32(_ at: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
    }
    @inline(__always) private func u8(_ at: Int) -> Int { Int(base.load(fromByteOffset: at, as: UInt8.self)) }
    private static func probability(_ q: Int) -> Float { exp2(-Float(q) / 16) }

    /// The words after `second` — or after `first` then `second` — likeliest first, with their
    /// probabilities, and the weight left over for the words of the shorter context.
    func after(_ first: Int?, _ second: Int) -> (words: [(word: Int, p: Float)], backoff: Float)? {
        let key = (first ?? Self.none, second)
        var low = 0, high = contexts
        while low < high {
            let mid = (low + high) / 2
            let at = tableOffset + Self.row * mid
            if (u32(at), u32(at + 4)) < key { low = mid + 1 } else { high = mid }
        }
        guard low < contexts else { return nil }
        let at = tableOffset + Self.row * low
        guard (u32(at), u32(at + 4)) == key else { return nil }
        let index = u32(at + 8), count = u8(at + 12)
        let words = (0..<count).map { i -> (word: Int, p: Float) in
            let e = entriesOffset + 5 * (index + i)
            return (u32(e), Self.probability(u8(e + 4)))
        }
        return (words, Self.probability(u8(at + 13)))
    }

    /// The likeliest next words: after the two words before when that pair was seen, the words
    /// after the last one weighed by what the pair leaves them.
    func predict(after first: Int?, _ second: Int, limit: Int) -> [(word: Int, p: Float)] {
        var p: [Int: Float] = [:]
        let pair = after(nil, second)
        if let first, let triple = after(first, second) {
            for (w, q) in triple.words { p[w] = q }
            for (w, q) in pair?.words ?? [] { p[w] = max(p[w] ?? 0, triple.backoff * q) }
        } else {
            for (w, q) in pair?.words ?? [] { p[w] = q }
        }
        return p.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(limit).map { ($0.key, $0.value) }
    }
}
