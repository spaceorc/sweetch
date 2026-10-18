import Foundation

/// How well sweetch does, in numbers without any text: for the iPhone app to show (`/metrics`),
/// and one day for the user to share. Counted from what this Mac keeps — the dictations and the
/// iPhone keyboard's log (both synced between the Macs) — per day, for the last two weeks.
enum Metrics {
    /// One day's counts.
    struct Day {
        var typedWords = 0
        var suggestionWords = 0
        var autocorrected = 0
        var autocorrectUndone = 0
        var deletes = 0
        var typosLeft = 0
        /// Seconds between words typed one after another (a pause over 8 s isn't typing).
        var typingGaps: [Double] = []
        var dictations = 0
        var dictatedWords = 0
        var phoneDictations = 0
        var recordingSeconds = 0.0
        /// From release to text, each dictation.
        var latencies: [Double] = []
        /// Dictations the keyboard saw to the end, and how many of their words the user changed.
        var finalWords = 0
        var changedWords = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String: (Date, Day)] = [:]

    static func compute(days count: Int = 14) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayNames = (0..<count).reversed().map { offset in
            dayName(calendar.date(byAdding: .day, value: -offset, to: today)!)
        }
        var days: [String: Day] = Dictionary(uniqueKeysWithValues: dayNames.map { ($0, Day()) })
        keyboard(into: &days)
        dictations(into: &days)

        let series = dayNames.map { name -> [String: Any] in
            let d = days[name]!
            return [
                "day": name, "typed_words": d.typedWords, "dictated_words": d.dictatedWords,
                "dictations": d.dictations, "autocorrected": d.autocorrected, "undone": d.autocorrectUndone,
                "latency_median": median(d.latencies) ?? NSNull(),
            ]
        }
        // The last seven days, together.
        let week = dayNames.suffix(7).map { days[$0]! }
        let typed = week.reduce(0) { $0 + $1.typedWords }
        let dictated = week.reduce(0) { $0 + $1.dictatedWords }
        let latencies = week.flatMap(\.latencies)
        let gaps = days.values.flatMap(\.typingGaps)
        let typingSecondsPerWord = median(gaps) ?? 1.2
        let recording = week.reduce(0) { $0 + $1.recordingSeconds }
        let speakingSecondsPerWord = dictated > 0 ? recording / Double(dictated) : 0.5
        // Dictating instead of typing: what typing those words would have taken, less speaking them
        // and waiting for the text.
        let saved = Double(dictated) * typingSecondsPerWord - recording - latencies.reduce(0, +)
        let finalWords = week.reduce(0) { $0 + $1.finalWords }
        let changed = week.reduce(0) { $0 + $1.changedWords }
        let autocorrected = week.reduce(0) { $0 + $1.autocorrected }
        let undone = week.reduce(0) { $0 + $1.autocorrectUndone }
        let totals: [String: Any] = [
            "typed_words": typed, "dictated_words": dictated,
            "dictations": week.reduce(0) { $0 + $1.dictations },
            "phone_dictations": week.reduce(0) { $0 + $1.phoneDictations },
            "dictated_share": typed + dictated > 0 ? Double(dictated) / Double(typed + dictated) : 0,
            "latency_median": median(latencies) ?? NSNull(),
            "latency_p90": percentile(latencies, 0.9) ?? NSNull(),
            "saved_minutes": max(0, saved / 60),
            "typing_wpm": 60 / typingSecondsPerWord,
            "speaking_wpm": speakingSecondsPerWord > 0 ? 60 / speakingSecondsPerWord : 0,
            "dictation_words_checked": finalWords,
            "dictation_edit_rate": finalWords > 0 ? Double(changed) / Double(finalWords) : NSNull(),
            "autocorrected": autocorrected,
            "autocorrect_undone_rate": autocorrected > 0 ? Double(undone) / Double(autocorrected) : 0,
            "deletes_per_100": typed > 0 ? Double(week.reduce(0) { $0 + $1.deletes }) * 100 / Double(typed) : 0,
            "typos_left_per_100": typed > 0 ? Double(week.reduce(0) { $0 + $1.typosLeft }) * 100 / Double(typed) : 0,
            "suggestion_share": typed > 0 ? Double(week.reduce(0) { $0 + $1.suggestionWords }) / Double(typed) : 0,
        ]
        return ["days": series, "week": totals, "computed_at": Date().timeIntervalSince1970]
    }

    // MARK: - The keyboard's log

    /// Only these lines are read (the log is mostly touches).
    private static let wanted = ["\"e\":\"word\"", "\"e\":\"autocorrect\"", "\"e\":\"autofix-undone\"", "\"e\":\"delete",
                                 "\"e\":\"decoder\"", "\"e\":\"dictation-final\""]

    private static func keyboard(into days: inout [String: Day]) {
        let dir = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let name = String(file.lastPathComponent.prefix(10))
            guard days[name] != nil else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let day = lock.withLock { cached[file.path].flatMap { $0.0 == modified ? $0.1 : nil } } ?? {
                let counted = countKeyboard(file)
                lock.withLock { cached[file.path] = (modified, counted) }
                return counted
            }()
            days[name]!.add(day)
        }
    }

    private static func countKeyboard(_ file: URL) -> Day {
        var day = Day()
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return day }
        var lastWord: (t: Double, session: String)?
        var seenLines = Set<String>()
        for line in text.split(separator: "\n") where wanted.contains(where: { line.contains($0) }) {
            // The same line twice (a batch sent again) counts once.
            guard seenLines.insert(String(line)).inserted,
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let name = event["e"] as? String else { continue }
            let t = event["t"] as? Double ?? 0
            switch name {
            case "word":
                day.typedWords += 1
                if event["boundary"] as? String == "suggestion" { day.suggestionWords += 1 }
                let session = event["session"] as? String ?? ""
                if let last = lastWord, last.session == session, t - last.t > 0, t - last.t < 8 { day.typingGaps.append(t - last.t) }
                lastWord = (t, session)
            case "autocorrect": day.autocorrected += 1
            case "autofix-undone": day.autocorrectUndone += 1
            case "delete", "delete-word": day.deletes += 1
            case "decoder":
                // A word the decoder took for no word, had a better one for, and left as typed.
                let literal = (event["literal"] as? String ?? "").lowercased()
                let top = (event["top"] as? [String])?.first?.lowercased()
                if event["literal_is_word"] as? Bool == false, (event["correction"] as? String ?? "").isEmpty,
                   let top, top != literal, literal.count > 2 { day.typosLeft += 1 }
            case "dictation-final":
                guard event["found"] as? Bool == true else { continue }
                let heard = words(event["heard"] as? String ?? ""), final = words(event["final"] as? String ?? "")
                day.finalWords += heard.count
                day.changedWords += max(heard.count, final.count) - commonRun(heard, final)
            default: break
            }
        }
        return day
    }

    // MARK: - Dictations

    private static func dictations(into days: inout [String: Day]) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let name = String(dir.lastPathComponent.prefix(10))
            guard days[name] != nil,
                  let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                  let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let text = session["inserted"] as? String ?? session["text"] as? String, !text.isEmpty else { continue }
            days[name]!.dictations += 1
            days[name]!.dictatedWords += words(text).count
            if session["device"] as? String == "iPhone" { days[name]!.phoneDictations += 1 }
            if let seconds = session["seconds"] as? Double { days[name]!.latencies.append(seconds) }
            days[name]!.recordingSeconds += session["recording_seconds"] as? Double ?? 0
        }
    }

    // MARK: - Helpers

    private static func dayName(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// The longest common subsequence's length.
    private static func commonRun(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }

    private static func median(_ values: [Double]) -> Double? { percentile(values, 0.5) }

    private static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p + 0.5))]
    }
}

private extension Metrics.Day {
    mutating func add(_ other: Metrics.Day) {
        typedWords += other.typedWords
        suggestionWords += other.suggestionWords
        autocorrected += other.autocorrected
        autocorrectUndone += other.autocorrectUndone
        deletes += other.deletes
        typosLeft += other.typosLeft
        typingGaps += other.typingGaps
    }
}
