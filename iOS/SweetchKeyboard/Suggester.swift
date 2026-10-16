import UIKit

/// Words the one being typed may be, from the system's dictionary — on a queue of its own, with a
/// checker of its own, so the keys never wait on it.
final class Suggester: @unchecked Sendable {
    static let shared = Suggester()

    private let queue = DispatchQueue(label: "sweetch.suggester", qos: .userInitiated)
    private var checker: UITextChecker?
    /// Only the latest word is worth working out: one asked while another is still being looked
    /// up replaces it.
    private var latest = 0
    private let lock = NSLock()

    /// Loads both languages' dictionaries now, not on the first key.
    func warmUp() {
        queue.async { [self] in
            let started = Date()
            _ = words(for: "пр")
            _ = words(for: "th")
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async { KeyLog.note("suggest-warm", ["ms": Int(seconds * 1000)]) }
        }
    }

    /// `done` runs on the main thread with up to three words and how long they took.
    func suggest(for word: String, done: @escaping @MainActor ([String], Double) -> Void) {
        let ticket = lock.withLock {
            latest += 1
            return latest
        }
        queue.async { [self] in
            guard lock.withLock({ latest == ticket }) else { return }
            let started = Date()
            let found = words(for: word)
            let seconds = Date().timeIntervalSince(started)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(found, seconds) } }
        }
    }

    private func words(for word: String) -> [String] {
        let checker = checker ?? UITextChecker()
        self.checker = checker
        let cyrillic = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let language = cyrillic ? "ru_RU" : "en_US"
        guard UITextChecker.availableLanguages.contains(language) else { return [] }
        let range = NSRange(location: 0, length: (word as NSString).length)
        var found: [String] = []
        if checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language).location != NSNotFound {
            found += checker.guesses(forWordRange: range, in: word, language: language) ?? []
        }
        if word.count > 1 {
            found += checker.completions(forPartialWordRange: range, in: word, language: language) ?? []
        }
        let capital = word.first?.isUppercase == true
        var seen: Set<String> = [word.lowercased()]
        var picked: [String] = []
        for candidate in found where !candidate.contains(" ") {
            let shown = capital ? candidate.prefix(1).uppercased() + candidate.dropFirst() : candidate
            guard seen.insert(shown.lowercased()).inserted else { continue }
            picked.append(shown)
            if picked.count == 3 { break }
        }
        return picked
    }
}
