import Foundation

/// The words the user types on the phone, counted, and lifted in the suggestions the more often
/// they come. One count for all the writing: the profiles (personal, work, agent) it was once
/// split by are gone — a way of writing the user had to pick, or the keyboard to guess, that the
/// bench couldn't tell from noise. Their counts are merged in, once.
final class WordMemory {
    private let defaults = UserDefaults.standard
    private var counts: [Int: Int]
    private var changed = 0

    init() {
        if let data = defaults.data(forKey: "wordCounts"), let stored = try? JSONDecoder().decode([String: Int].self, from: data) {
            counts = Dictionary(uniqueKeysWithValues: stored.compactMap { k, v in Int(k).map { ($0, v) } })
        } else {
            counts = [:]
            let old = defaults.data(forKey: "profileCounts").flatMap { try? JSONDecoder().decode([[String: Int]].self, from: $0) } ?? []
            for profile in old { for (k, v) in profile { if let node = Int(k) { counts[node, default: 0] += v } } }
            for key in ["profileCounts", "profileByProcess", "profileLast"] { defaults.removeObject(forKey: key) }
            save(soon: false)
        }
    }

    /// A word finished.
    func add(_ word: Int) {
        counts[word, default: 0] += 1
        save(soon: true)
    }

    /// The words typed, lifted the more often (0–40 on the 0–255 scale).
    func boosts() -> [Int: Int] {
        counts.compactMapValues { $0 >= 2 ? min(40, 8 + Int(4 * log2(Double($0)))) : nil }
    }

    private func save(soon: Bool) {
        changed += 1
        guard !soon || changed >= 5 else { return }
        changed = 0
        // Keep the most used words when it grows large.
        if counts.count > 6000 { counts = Dictionary(uniqueKeysWithValues: counts.sorted { $0.value > $1.value }.prefix(5000).map { ($0.key, $0.value) }) }
        if let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: counts.map { (String($0.key), $0.value) })) {
            defaults.set(data, forKey: "wordCounts")
        }
    }
}
