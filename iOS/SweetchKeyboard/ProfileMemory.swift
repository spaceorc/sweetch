import Foundation

/// What the keyboard learns of the user's three ways of writing on the phone itself, used only on
/// the decoder's queue: the profile each app's process was last in, how often each word was typed
/// in each profile (lifting it there), and the session being typed — its words and how well each
/// profile explains them, to tell which one the user is in.
///
/// The facts — every word, its session, the session's profile — also go to the Mac's log, where
/// the profiles are counted again from scratch at the next build of the lexicon.
final class ProfileMemory {
    typealias Name = Profiles.Name

    private let defaults = UserDefaults.standard
    private var byProcess: [String: Int]
    private var counts: [[Int: Int]]
    private var changed = 0

    /// The session: its words (lexicon nodes), each profile's score for them.
    private(set) var words: [Int] = []
    private(set) var scores: [Double] = [0, 0, 0]

    init() {
        byProcess = defaults.dictionary(forKey: "profileByProcess") as? [String: Int] ?? [:]
        let stored = (defaults.data(forKey: "profileCounts")).flatMap { try? JSONDecoder().decode([[String: Int]].self, from: $0) }
        counts = (stored ?? [[:], [:], [:]]).map { Dictionary(uniqueKeysWithValues: $0.compactMap { k, v in Int(k).map { ($0, v) } }) }
        while counts.count < 3 { counts.append([:]) }
    }

    /// Where a new session starts: the profile this process was in last, else the last one used.
    func start(process: Int32?) -> Name {
        words = []
        let last = process.flatMap { byProcess[String($0)] } ?? defaults.integer(forKey: "profileLast")
        let name = Name(rawValue: last) ?? .agent
        scores = [0, 0, 0]
        scores[name.rawValue] = 1.5   // the process's last profile, until the words say otherwise
        return name
    }

    /// A word finished in `profile`: counted there, and each profile's score moved by how much
    /// likelier the word is in it. Returns the profile the words now point to.
    func add(_ word: Int, in profile: Name, profiles: Profiles?) -> Name {
        words.append(word)
        counts[profile.rawValue][word, default: 0] += 1
        if let profiles {
            for name in Name.allCases { scores[name.rawValue] += 0.5 * Double(profiles.weight(of: word, in: name)) }
        }
        save(soon: true)
        let best = Name.allCases.max { scores[$0.rawValue] < scores[$1.rawValue] }!
        // Only a clear lead moves it: one odd word mustn't flip the profile back and forth.
        return scores[best.rawValue] - scores[profile.rawValue] >= 1.5 ? best : profile
    }

    /// The session goes to another profile: its words counted there instead, and the process
    /// remembered in it.
    func move(from old: Name, to new: Name, process: Int32?) {
        if old != new {
            for word in words {
                counts[old.rawValue][word, default: 1] -= 1
                if counts[old.rawValue][word]! <= 0 { counts[old.rawValue][word] = nil }
                counts[new.rawValue][word, default: 0] += 1
            }
        }
        remember(new, process: process)
    }

    func remember(_ name: Name, process: Int32?) {
        if let process { byProcess[String(process)] = name.rawValue }
        if byProcess.count > 30 { byProcess = Dictionary(uniqueKeysWithValues: byProcess.suffix(20).map { ($0.key, $0.value) }) }
        defaults.set(name.rawValue, forKey: "profileLast")
        save(soon: false)
    }

    /// Words typed in the profile on the phone, lifted the more often (0–40 on the 0–255 scale).
    func boosts(for name: Name) -> [Int: Int] {
        counts[name.rawValue].compactMapValues { $0 >= 2 ? min(40, 8 + Int(4 * log2(Double($0)))) : nil }
    }

    private func save(soon: Bool) {
        changed += 1
        guard !soon || changed >= 5 else { return }
        changed = 0
        // Keep the most used words when a profile grows large.
        counts = counts.map { $0.count > 3000 ? Dictionary(uniqueKeysWithValues: $0.sorted { $0.value > $1.value }.prefix(2500).map { ($0.key, $0.value) }) : $0 }
        defaults.set(byProcess, forKey: "profileByProcess")
        if let data = try? JSONEncoder().encode(counts.map { Dictionary(uniqueKeysWithValues: $0.map { (String($0.key), $0.value) }) }) {
            defaults.set(data, forKey: "profileCounts")
        }
    }
}
