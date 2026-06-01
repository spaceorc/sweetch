import Cocoa

struct Keystroke {
    let keyCode: Int64
    let flags: CGEventFlags
    let chars: String
    let sourceID: String
    let timestamp: Date
}

final class KeystrokeBuffer {
    private var buffer: [Keystroke] = []
    private let capacity: Int
    private let idleTimeout: TimeInterval

    init(capacity: Int = 200, idleTimeout: TimeInterval = 10.0) {
        self.capacity = capacity
        self.idleTimeout = idleTimeout
    }

    func append(_ k: Keystroke) {
        if let last = buffer.last, k.timestamp.timeIntervalSince(last.timestamp) > idleTimeout {
            buffer.removeAll(keepingCapacity: true)
        }
        buffer.append(k)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    func clear(reason: String) {
        if !buffer.isEmpty {
            log.info("buffer clear: \(reason, privacy: .public) (dropped \(self.buffer.count, privacy: .public) keystrokes)")
        }
        buffer.removeAll(keepingCapacity: true)
    }

    func snapshot() -> [Keystroke] { buffer }

    var isEmpty: Bool { buffer.isEmpty }

    /// Range of (last word + any trailing whitespace). The trailing whitespace is
    /// included because cursor sits after it, so the backspaces have to remove it,
    /// and we re-emit it from the same keystrokes.
    func lastWordRange() -> Range<Int>? {
        guard !buffer.isEmpty else { return nil }
        var end = buffer.count
        while end > 0 && isWhitespace(buffer[end - 1]) {
            end -= 1
        }
        guard end > 0 else { return nil }
        var start = end
        while start > 0 && !isWhitespace(buffer[start - 1]) {
            start -= 1
        }
        return start..<buffer.count
    }

    /// Update the sourceID of entries in `range` after a replay. Lets a second
    /// convert press toggle back.
    func relabel(range: Range<Int>, sourceID newSourceID: String) {
        guard range.lowerBound >= 0, range.upperBound <= buffer.count else { return }
        for i in range {
            let old = buffer[i]
            buffer[i] = Keystroke(
                keyCode: old.keyCode,
                flags: old.flags,
                chars: old.chars,
                sourceID: newSourceID,
                timestamp: old.timestamp
            )
        }
    }

    private func isWhitespace(_ k: Keystroke) -> Bool {
        k.keyCode == 49 // space
    }
}
