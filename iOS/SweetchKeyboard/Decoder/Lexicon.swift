import Foundation

/// The words the decoder looks for, read straight from the file Tools/keyboard/build_lexicon.py
/// writes: memory-mapped, so its half a million words cost the keyboard no memory of its own —
/// nothing here becomes a string until a word is asked for.
///
/// A trie: node 0 is the root; a node's children are contiguous and sorted by letter; a node
/// with a frequency ends a word.
final class Lexicon {
    let alphabet: [Character]
    private let letters: [Character: UInt8]
    let nodeCount: Int
    private let base: UnsafeRawPointer
    private let size: Int
    private let firstOffset, countOffset, labelOffset, frequencyOffset, flagsOffset: Int
    private let writtenAs: [String: String]

    static let capitalised: UInt8 = 1, allCapitals: UInt8 = 2, oddCase: UInt8 = 4, personal: UInt8 = 8

    init?(url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 16 else { return nil }
        size = Int(info.st_size)
        guard let mapped = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), mapped != MAP_FAILED else { return nil }
        let p = UnsafeRawPointer(mapped)
        func u32(_ at: Int) -> Int { Int(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        guard String(decoding: UnsafeRawBufferPointer(start: p, count: 4), as: UTF8.self) == "SWLX", u32(4) == 1 else {
            munmap(mapped, size)
            return nil
        }
        var at = 8
        let alphabetSize = u32(at); at += 4
        var alphabet: [Character] = []
        for i in 0..<alphabetSize {
            alphabet.append(Character(Unicode.Scalar(UInt32(u32(at + 4 * i)))!))
        }
        at += 4 * alphabetSize
        self.alphabet = alphabet
        letters = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
        nodeCount = u32(at); at += 4
        firstOffset = at; at += 4 * nodeCount
        countOffset = at; at += nodeCount
        labelOffset = at; at += nodeCount
        frequencyOffset = at; at += nodeCount
        flagsOffset = at; at += nodeCount
        var writtenAs: [String: String] = [:]
        let casings = u32(at); at += 4
        func u16(_ at: Int) -> Int { Int(UInt16(littleEndian: p.loadUnaligned(fromByteOffset: at, as: UInt16.self))) }
        for _ in 0..<casings {
            let keyLength = u16(at); at += 2
            let key = String(decoding: UnsafeRawBufferPointer(start: p + at, count: keyLength), as: UTF8.self); at += keyLength
            let formLength = u16(at); at += 2
            writtenAs[key] = String(decoding: UnsafeRawBufferPointer(start: p + at, count: formLength), as: UTF8.self); at += formLength
        }
        self.writtenAs = writtenAs
        base = p
    }

    deinit { munmap(UnsafeMutableRawPointer(mutating: base), size) }

    @inline(__always) func firstChild(_ node: Int) -> Int {
        Int(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: firstOffset + 4 * node, as: UInt32.self)))
    }
    @inline(__always) func childCount(_ node: Int) -> Int { Int(base.load(fromByteOffset: countOffset + node, as: UInt8.self)) }
    @inline(__always) func label(_ node: Int) -> UInt8 { base.load(fromByteOffset: labelOffset + node, as: UInt8.self) }
    @inline(__always) func frequency(_ node: Int) -> UInt8 { base.load(fromByteOffset: frequencyOffset + node, as: UInt8.self) }
    @inline(__always) func flags(_ node: Int) -> UInt8 { base.load(fromByteOffset: flagsOffset + node, as: UInt8.self) }

    func children(_ node: Int) -> Range<Int> {
        let first = firstChild(node)
        return first..<first + childCount(node)
    }

    /// The child reached by `letter`, if any.
    func child(_ node: Int, _ letter: UInt8) -> Int? {
        var range = children(node)
        while !range.isEmpty {
            let mid = range.lowerBound + range.count / 2
            let here = label(mid)
            if here == letter { return mid }
            if here < letter { range = mid + 1..<range.upperBound } else { range = range.lowerBound..<mid }
        }
        return nil
    }

    func index(of character: Character) -> UInt8? { letters[character] }

    /// The node a word ends at, if it's a word.
    func lookup(_ word: String) -> Int? {
        var node = 0
        for character in word.lowercased() {
            guard let letter = letters[character], let next = child(node, letter) else { return nil }
            node = next
        }
        return frequency(node) > 0 ? node : nil
    }

    /// The word a node ends: its letters found by walking up from it — nodes are breadth-first,
    /// so a node's parent is the one whose children span it.
    func word(at node: Int) -> String {
        var path: [UInt8] = []
        var current = node
        while current != 0 {
            path.append(label(current))
            // The parent: the last node whose first child is at or before this one.
            var low = 0, high = current
            while low < high {
                let mid = (low + high + 1) / 2
                if firstChild(mid) <= current, childCount(mid) > 0 || firstChild(mid) <= current { low = mid } else { high = mid - 1 }
            }
            while low > 0, !(firstChild(low) <= current && current < firstChild(low) + childCount(low)) { low -= 1 }
            current = low
        }
        return word(path.reversed(), node: node)
    }

    /// A word spelled by its letters, written as the lexicon writes it.
    func word(_ path: [UInt8], node: Int) -> String {
        let lower = String(path.map { alphabet[Int($0)] })
        let flags = self.flags(node)
        if flags & Self.oddCase != 0, let written = writtenAs[lower] { return written }
        if flags & Self.allCapitals != 0 { return lower.uppercased() }
        if flags & Self.capitalised != 0 { return lower.prefix(1).uppercased() + lower.dropFirst() }
        return lower
    }
}
