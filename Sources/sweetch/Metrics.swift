import Foundation

/// How well sweetch does, in numbers without any text: for the iPhone app to show (`/metrics`),
/// and one day for the user to share. Counted from what this Mac keeps — the dictations and the
/// iPhone keyboard's log (both synced between the Macs) — per day, for the last two weeks.
enum Metrics {
    /// One day's counts.
    struct Day: Codable {
        var typedWords = 0
        var suggestionWords = 0
        var autocorrected = 0
        var autocorrectUndone = 0
        var deletes = 0
        var typosLeft = 0
        /// Fixing by hand: each run of backspaces (under 2 s apart, at most 40 characters — more is
        /// rewriting, not a typo), its characters and how long the backspacing took; and the
        /// suggestions picked in place of a word typed wrong.
        var fixes: [Fix] = []
        var suggestionFixes = 0
        var wordLetters = 0
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

    struct Fix: Codable {
        let chars: Int
        let seconds: Double
    }

    /// What each file came to (Stats): a keyboard log's day, a dictation's numbers, a keyboard
    /// log's calls to models.
    private static let keyboardDigests = LogDigests<KeyboardCount>("metrics-keyboard", version: 1)
    private static let dictationDigests = DigestCache<Dictated>("metrics-dictations", version: 1)
    private static let llmDigests = LogDigests<[String]>("metrics-llm", version: 1)

    static func saveDigests() {
        keyboardDigests.save()
        dictationDigests.save()
        llmDigests.save()
    }

    static func compute(days count: Int = 14) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayNames = (0..<count).reversed().map { offset in
            dayName(calendar.date(byAdding: .day, value: -offset, to: today)!)
        }
        var days: [String: Day] = Dictionary(uniqueKeysWithValues: dayNames.map { ($0, Day()) })
        keyboard(into: &days)
        dictations(into: &days)

        let gaps = days.values.flatMap(\.typingGaps)
        let typingSecondsPerWord = median(gaps) ?? 1.2
        let letters = days.values.reduce(0) { $0 + $1.wordLetters }, typedAll = days.values.reduce(0) { $0 + $1.typedWords }
        // A character's time while typing: a word and the space after it.
        let secondsPerChar = typingSecondsPerWord / (typedAll > 0 ? Double(letters) / Double(typedAll) + 1 : 6)
        /// A fix by hand: the backspacing, typing the characters again, and half a second to notice.
        func fixSeconds(_ fix: Fix) -> Double { fix.seconds + Double(fix.chars) * secondsPerChar + 0.5 }
        let medianFix = median(days.values.flatMap(\.fixes).map(fixSeconds)) ?? 2.5
        let per100 = { (n: Int, words: Int) -> Any in words > 0 ? Double(n) * 100 / Double(words) : NSNull() }
        let series = dayNames.map { name -> [String: Any] in
            let d = days[name]!
            return [
                "good_autocorrect_per_100": per100(d.autocorrected - d.autocorrectUndone, d.typedWords),
                "undone_per_100": per100(d.autocorrectUndone, d.typedWords),
                "fixes_per_100": per100(d.fixes.count + d.suggestionFixes, d.typedWords),
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
            "good_autocorrect_per_100": per100(autocorrected - undone, typed),
            "undone_per_100": per100(undone, typed),
            "fixes_per_100": per100(week.reduce(0) { $0 + $1.fixes.count + $1.suggestionFixes }, typed),
            "fixing_minutes": week.flatMap(\.fixes).map(fixSeconds).reduce(0, +) / 60
                + Double(week.reduce(0) { $0 + $1.suggestionFixes }) * 1.0 / 60,
            "autocorrect_saved_minutes": Double(max(0, autocorrected - undone)) * medianFix / 60,
            "autocorrect_lost_minutes": Double(undone) * medianFix / 60,
            "fix_seconds_median": medianFix,
            "suggestion_share": typed > 0 ? Double(week.reduce(0) { $0 + $1.suggestionWords }) / Double(typed) : 0,
        ]
        return ["days": series, "week": totals, "llm": llm(dayNames: dayNames), "computed_at": Date().timeIntervalSince1970]
    }

    // MARK: - What the models cost

    /// The calls to models and what they cost (LLMUsage): the Macs' own (`llm-usage/`) and the
    /// iPhone's (`llm-usage` events in the keyboard's log) — today, the last seven days by what for
    /// and by model, each day of the last two weeks, and all that's kept.
    /// What the models cost alone — for the Mac's window, without counting all the rest.
    static func llmSummary(days count: Int = 14) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return llm(dayNames: (0..<count).reversed().map { dayName(calendar.date(byAdding: .day, value: -$0, to: today)!) })
    }

    private static func llm(dayNames: [String]) -> [String: Any] {
        var records: [[String: Any]] = []
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: LLMUsageLog.dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "jsonl" {
            for line in ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n") {
                if let r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] { records.append(r) }
            }
        }
        let keyboard = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        for url in (try? fm.contentsOfDirectory(at: keyboard, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "jsonl" {
            let lines = llmDigests.state(for: url, fresh: { [String]() }) { lines, text in
                lines += text.split(separator: "\n").filter { $0.contains("\"e\":\"llm-usage\"") }.map(String.init)
            }
            for line in lines {
                if var r = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] {
                    r["from"] = "iphone"
                    records.append(r)
                }
            }
        }
        let byDay = Dictionary(grouping: records) { dayName(Date(timeIntervalSince1970: ($0["t"] as? Double) ?? 0)) }
        func cost(_ rs: [[String: Any]]) -> Double { rs.reduce(0) { $0 + (($1["cost"] as? NSNumber)?.doubleValue ?? 0) } }
        let week = dayNames.suffix(7).flatMap { byDay[$0] ?? [] }
        func split(_ key: String) -> [[String: Any]] {
            Dictionary(grouping: week) { $0[key] as? String ?? "?" }
                .map { ["name": $0.key, "cost": cost($0.value), "calls": $0.value.count] }
                .sorted { ($0["cost"] as! Double) > ($1["cost"] as! Double) }
        }
        return [
            "today": cost(byDay[dayNames.last ?? ""] ?? []),
            "week": cost(week), "week_calls": week.count,
            "all": cost(records), "since": records.compactMap { $0["t"] as? Double }.min() ?? NSNull(),
            "by_purpose": split("purpose"), "by_model": split("model"),
            "days": dayNames.map { ["day": $0, "cost": cost(byDay[$0] ?? [])] },
            // Every day kept, by what for — for the window's chart by day, week and month.
            "history": byDay.keys.sorted().map { day -> [String: Any] in
                let rs = byDay[day]!
                return ["day": day, "cost": cost(rs), "calls": rs.count,
                        "by_purpose": Dictionary(grouping: rs) { $0["purpose"] as? String ?? "?" }.mapValues(cost),
                        "by_model": Dictionary(grouping: rs) { $0["model"] as? String ?? "?" }.mapValues(cost),
                        "by_device": Dictionary(grouping: rs) { $0["from"] as? String ?? "mac" }.mapValues(cost)]
            },
        ]
    }

    // MARK: - The keyboard's log

    /// Only these lines are read (the log is mostly touches).
    private static let wanted = ["\"e\":\"word\"", "\"e\":\"autocorrect\"", "\"e\":\"autofix-undone\"", "\"e\":\"delete",
                                 "\"e\":\"decoder\"", "\"e\":\"dictation-final\"", "\"e\":\"choose\"",
                                 "\"e\":\"type\""]

    private static func keyboard(into days: inout [String: Day]) {
        let dir = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let name = String(file.lastPathComponent.prefix(10))
            guard days[name] != nil else { continue }
            days[name]!.add(countKeyboard(file))
        }
    }

    /// The keyboard log read so far (LogDigests): the day's counts, and where the reading stands —
    /// the last word, a run of ⌫ still going, a fix maybe being taken back, the lines seen.
    struct KeyboardCount: Codable {
        var day = Day()
        var lastWordT: Double?
        var lastWordSession = ""
        var runChars = 0, runFirst = 0.0, runLast = 0.0
        var running = false
        // A fix ⌫ took back, while the ⌫s may still go on through the whole word: then the user was
        // deleting it, not refusing the fix, and it counts neither way.
        var takenBackLen: Int?
        var takenBackLetters = 0
        var seen = Set<UInt64>()

        mutating func endRun() {
            if running, runChars <= 40 { day.fixes.append(Fix(chars: runChars, seconds: runLast - runFirst)) }
            running = false
        }

        /// The day as counted to the end of the log: a run of ⌫ at its end ends there.
        var finished: Day {
            var copy = self
            copy.endRun()
            return copy.day
        }
    }

    private static func countKeyboard(_ file: URL) -> Day {
        keyboardDigests.state(for: file, fresh: { KeyboardCount() }, read: countKeyboard).finished
    }

    private static func countKeyboard(_ c: inout KeyboardCount, _ text: Substring) {
        for line in text.split(separator: "\n") where wanted.contains(where: { line.contains($0) }) {
            // The same line twice (a batch sent again) counts once.
            guard c.seen.insert(LogDigests<KeyboardCount>.lineHash(line)).inserted,
                  let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let name = event["e"] as? String else { continue }
            let t = event["t"] as? Double ?? 0
            if name == "delete" || name == "delete-word" {
                let chars = name == "delete" ? 1 : event["chars"] as? Int ?? 1
                if c.running, t - c.runLast < 2 {
                    c.runChars += chars
                    c.runLast = t
                } else {
                    c.endRun()
                    (c.running, c.runChars, c.runFirst, c.runLast) = (true, chars, t, t)
                }
            } else if c.running, t - c.runLast >= 2 || name == "word" {
                c.endRun()
            }
            switch name {
            case "word":
                c.day.typedWords += 1
                c.day.wordLetters += (event["word"] as? String ?? "").count
                if event["boundary"] as? String == "suggestion" { c.day.suggestionWords += 1 }
                let session = event["session"] as? String ?? ""
                if let last = c.lastWordT, c.lastWordSession == session, t - last > 0, t - last < 8 { c.day.typingGaps.append(t - last) }
                (c.lastWordT, c.lastWordSession) = (t, session)
            case "choose":
                // A suggestion in place of the word typed, not its ending: a typo put right by hand.
                let typed = (event["word"] as? String ?? "").lowercased(), picked = (event["suggestion"] as? String ?? "").lowercased()
                if !typed.isEmpty, !picked.hasPrefix(typed) { c.day.suggestionFixes += 1 }
            case "autocorrect": c.day.autocorrected += 1
            case "autofix-undone":
                c.day.autocorrectUndone += 1
                if event["by"] as? String == "delete", let len = event["before_len"] as? Int {
                    (c.takenBackLen, c.takenBackLetters) = (len, (event["typed"] as? String ?? "").count)
                }
            case "delete", "delete-word":
                c.day.deletes += 1
                if let back = c.takenBackLen, let len = event["before_len"] as? Int, len <= back - c.takenBackLetters {
                    c.day.autocorrectUndone -= 1
                    c.day.autocorrected -= 1
                    c.takenBackLen = nil
                }
            case "decoder":
                // A word the decoder took for no word, had a better one for, and left as typed.
                let literal = (event["literal"] as? String ?? "").lowercased()
                let top = (event["top"] as? [String])?.first?.lowercased()
                if event["literal_is_word"] as? Bool == false, (event["correction"] as? String ?? "").isEmpty,
                   let top, top != literal, literal.count > 2 { c.day.typosLeft += 1 }
            case "dictation-final":
                guard event["found"] as? Bool == true else { continue }
                let heard = words(event["heard"] as? String ?? ""), final = words(event["final"] as? String ?? "")
                c.day.finalWords += heard.count
                c.day.changedWords += max(heard.count, final.count) - commonRun(heard, final)
            default: break
            }
            if name != "delete", name != "delete-word", name != "autofix-undone" { c.takenBackLen = nil }
        }
    }

    // MARK: - Dictations

    /// A dictation's numbers; `words` nil when nothing was typed (cancelled, handed over, nothing heard).
    struct Dictated: Codable {
        var words: Int?
        var phone = false
        var seconds: Double?
        var recording = 0.0
    }

    private static func dictations(into days: inout [String: Day]) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs {
            let name = String(dir.lastPathComponent.prefix(10))
            guard days[name] != nil else { continue }
            let d = dictationDigests.value(for: dir.appendingPathComponent("session.json")) { url in
                guard let data = try? Data(contentsOf: url),
                      let session = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let text = session["inserted"] as? String ?? session["text"] as? String, !text.isEmpty else { return Dictated() }
                return Dictated(words: words(text).count, phone: session["device"] as? String == "iPhone",
                                seconds: session["seconds"] as? Double, recording: session["recording_seconds"] as? Double ?? 0)
            }
            guard let count = d.words else { continue }
            days[name]!.dictations += 1
            days[name]!.dictatedWords += count
            if d.phone { days[name]!.phoneDictations += 1 }
            if let seconds = d.seconds { days[name]!.latencies.append(seconds) }
            days[name]!.recordingSeconds += d.recording
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
        fixes += other.fixes
        suggestionFixes += other.suggestionFixes
        wordLetters += other.wordLetters
        typingGaps += other.typingGaps
    }
}
