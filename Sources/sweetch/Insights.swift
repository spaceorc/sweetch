import Foundation

/// What the numbers say about the user's hands and voice, for the iPhone app (`/insights`): where
/// the fingers land on each key — typing fast and typing slowly apart, they're two different
/// ways of typing — which taps became typos and which letters they were meant to be, how typos
/// grow with speed, how the phone is held — two thumbs or one finger, told by the touches' size and
/// whether alternating hands pays — and how a keyboard minding the offsets would have done, how
/// long dictations take to come back on each device, and which words whisper keeps being unsure
/// of. No text leaves the Mac but single words and letters.
enum Insights {
    /// A tap within this long of the one before is fast typing; after this long, a deliberate one.
    static let fast = 0.35
    static let slow = 0.6
    /// The heat map's cell, in points.
    static let cell = 4.0

    private struct Tap: Codable {
        let key: String
        let x: Double
        let y: Double
        let t: Double
        let interval: Double?
        let run: String
        /// The touch's major radius as iOS gives it (steps of about 12 pt).
        let radius: Double?
        /// "thumbs" or "finger", from the run of typing it's in.
        var posture: String?
    }

    private struct Fix: Codable {
        let typed: String
        let meant: String
        let t: Double
        let run: String
    }

    /// A keyboard log read: its letter taps, the words put right, and the Russian layout's keys
    /// (as the log has them, JSON).
    private struct KeyboardRead: Codable {
        var taps: [Tap] = []
        var fixes: [Fix] = []
        var layout = Data()
        /// Where the reading stands: each run's last key up, the touches down not yet up, the lines seen.
        var lastUp: [String: Double] = [:]
        var radius: [String: Double] = [:]
        var seen = Set<UInt64>()
    }

    /// A dictation's: how long it took to text and on what, and whisper's words, each [unsure, all].
    private struct Heard: Codable {
        var seconds: Double?
        var phone = false
        var words: [String: [Int]] = [:]
    }

    /// What each file came to (Stats).
    private static let keyboardDigests = LogDigests<KeyboardRead>("insights-keyboard", version: 1)
    private static let latencyDigests = DigestCache<Heard>("insights-latency", version: 1)
    private static let unsureDigests = DigestCache<Heard>("insights-unsure", version: 1)

    static func saveDigests() {
        keyboardDigests.save()
        latencyDigests.save()
        unsureDigests.save()
    }

    static func compute(days count: Int = 14) -> [String: Any] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let dayNames = Set((0..<count).map { f.string(from: calendar.date(byAdding: .day, value: -$0, to: today)!) })

        // The keyboard's log: taps, the words put right, the Russian layout's keys.
        var taps: [Tap] = []
        var fixes: [Fix] = []
        var layout: [[Any]] = []
        let dir = AppSupport.dir.appendingPathComponent("keyboard", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && dayNames.contains(String($0.lastPathComponent.prefix(10))) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            let read = readKeyboard(file)
            taps += read.taps
            fixes += read.fixes
            if let keys = (try? JSONSerialization.jsonObject(with: read.layout)) as? [[Any]], !keys.isEmpty { layout = keys }
        }
        taps.sort { $0.t < $1.t }

        // Each fixed word's letters lined up with the taps that typed them: the last taps of that
        // run before the fix, when they spell the word as typed.
        var errors: [(tap: Tap, meant: String)] = []
        var byRun: [String: [Tap]] = [:]
        for tap in taps { byRun[tap.run, default: []].append(tap) }
        for fix in fixes where fix.typed.count == fix.meant.count {
            guard let runTaps = byRun[fix.run] else { continue }
            let before = runTaps.lastIndex { $0.t <= fix.t } ?? -1
            let n = fix.typed.count
            guard before + 1 >= n else { continue }
            let word = Array(runTaps[(before + 1 - n)...before])
            guard word.map(\.key).joined() == fix.typed, word.last!.t > fix.t - 5 else { continue }
            for (i, (typed, meant)) in zip(fix.typed, fix.meant).enumerated() where typed != meant {
                errors.append((word[i], String(meant)))
            }
        }

        let keys = Dictionary(layout.compactMap { k -> (String, [Double])? in
            guard let name = k.first as? String, name.count == 1, k.count >= 5 else { return nil }
            return (name, k[1...4].compactMap { ($0 as? NSNumber)?.doubleValue })
        }) { a, _ in a }
        let isFast = { (tap: Tap) in (tap.interval ?? 9) < fast }
        let isSlow = { (tap: Tap) in (tap.interval ?? 9) >= slow }
        var letters = taps.filter { keys[$0.key] != nil }
        let postures = classifyPostures(&letters, width: keys.values.map { $0[0] + $0[2] }.max() ?? 440)
        let posture = Dictionary(letters.map { ("\($0.run)|\($0.t)", $0.posture) }) { a, _ in a }
        errors = errors.map { error in
            var tap = error.tap
            tap.posture = posture["\(tap.run)|\(tap.t)"] ?? nil
            return (tap, error.meant)
        }
        let byPosture = { (name: String) in letters.filter { $0.posture == name } }

        return [
            "keys": layout.filter { (($0.first as? String)?.count ?? 0) == 1 },
            "cell": cell,
            "heat": [
                "fast": grid(letters.filter(isFast).map { ($0.x, $0.y) }),
                "slow": grid(letters.filter(isSlow).map { ($0.x, $0.y) }),
                "errors": grid(errors.map { ($0.tap.x, $0.tap.y) }),
                "thumbs": grid(byPosture("thumbs").map { ($0.x, $0.y) }),
                "finger": grid(byPosture("finger").map { ($0.x, $0.y) }),
            ],
            "offsets": [
                "fast": offsets(letters.filter(isFast), keys),
                "slow": offsets(letters.filter(isSlow), keys),
                "errors": offsets(errors.map { e in Tap(key: e.meant, x: e.tap.x, y: e.tap.y, t: e.tap.t, interval: e.tap.interval,
                                                         run: e.tap.run, radius: nil, posture: nil) }, keys),
                "thumbs": offsets(byPosture("thumbs"), keys),
                "finger": offsets(byPosture("finger"), keys),
            ],
            "postures": postures.merging(Dictionary(uniqueKeysWithValues: ["thumbs", "finger"].map { name -> (String, Any) in
                let group = byPosture(name), groupErrors = errors.filter { $0.tap.posture == name }.count
                var stats = postures[name] as? [String: Any] ?? [:]
                stats["typos_per_100"] = group.isEmpty ? 0 : Double(groupErrors) * 100 / Double(group.count)
                return (name, stats)
            })) { _, b in b },
            "simulation": simulate(letters.filter(isFast), errors, keys),
            "taps": ["fast": letters.filter(isFast).count, "slow": letters.filter(isSlow).count, "all": letters.count,
                     "errors": errors.count],
            "confusions": confusions(errors),
            "tempo": tempo(letters, errors),
            "latency": latency(dayNames),
            "unsure": unsure(dayNames),
            "findings": findings(offsets(letters.filter(isFast), keys), keys, errors, letters, isFast, isSlow),
        ]
    }

    // MARK: - Reading the keyboard's log

    private static func readKeyboard(_ file: URL) -> KeyboardRead {
        keyboardDigests.state(for: file, fresh: { KeyboardRead() }, read: readKeyboard)
    }

    private static func readKeyboard(_ r: inout KeyboardRead, _ text: Substring) {
        for line in text.split(separator: "\n") {
            if line.contains("\"e\":\"down\""),
               let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let radius = e["radius"] as? Double {
                r.radius["\(e["run"] as? String ?? "")|\(e["touch"] as? Int ?? 0)"] = radius
                continue
            }
            let up = line.contains("\"e\":\"up\""), keysLine = line.contains("\"e\":\"keys\"")
            let fix = line.contains("\"e\":\"autocorrect\"") || line.contains("\"e\":\"choose\"")
            guard up || keysLine || fix, r.seen.insert(LogDigests<KeyboardRead>.lineHash(line)).inserted,
                  let e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let t = e["t"] as? Double ?? 0, run = e["run"] as? String ?? ""
            if up {
                let key = (e["key"] as? String ?? "").lowercased()
                let touch = "\(run)|\(e["touch"] as? Int ?? 0)"
                let radius = r.radius.removeValue(forKey: touch)
                defer { r.lastUp[run] = t }
                guard key.count == 1, key.first!.isLetter, let x = e["x"] as? Double, let y = e["y"] as? Double else { continue }
                r.taps.append(Tap(key: key, x: x, y: y, t: t, interval: r.lastUp[run].map { t - $0 }, run: run,
                                  radius: radius, posture: nil))
            } else if keysLine {
                if let k = e["keys"] as? [[Any]], k.contains(where: { $0.first as? String == "й" }) {
                    r.layout = (try? JSONSerialization.data(withJSONObject: k)) ?? Data()
                }
            } else {
                let typed = (e["typed"] as? String ?? e["word"] as? String ?? "").lowercased()
                let meant = (e["fixed"] as? String ?? e["suggestion"] as? String ?? "").lowercased()
                if !typed.isEmpty, typed != meant { r.fixes.append(Fix(typed: typed, meant: meant, t: t, run: run)) }
            }
        }
    }

    // MARK: - Parts

    /// Taps counted per cell: [[column, row, count]].
    private static func grid(_ points: [(Double, Double)]) -> [[Int]] {
        var cells: [Int: Int] = [:]
        for (x, y) in points where x >= 0 && y >= 0 {
            cells[Int(x / cell) << 16 | Int(y / cell), default: 0] += 1
        }
        return cells.map { [$0.key >> 16, $0.key & 0xFFFF, $0.value] }
    }

    /// Where the finger lands on each letter, from its key's centre: {letter: [dx, dy, taps]}.
    private static func offsets(_ taps: [Tap], _ keys: [String: [Double]]) -> [String: [Double]] {
        var sums: [String: (Double, Double, Int)] = [:]
        for tap in taps {
            guard let k = keys[tap.key], k.count == 4 else { continue }
            let s = sums[tap.key] ?? (0, 0, 0)
            sums[tap.key] = (s.0 + tap.x - (k[0] + k[2] / 2), s.1 + tap.y - (k[1] + k[3] / 2), s.2 + 1)
        }
        return sums.filter { $0.value.2 >= 10 }.mapValues { [($0.0 / Double($0.2) * 10).rounded() / 10, ($0.1 / Double($0.2) * 10).rounded() / 10, Double($0.2)] }
    }

    /// The letters most often typed for others: [[meant, typed, times, share typed fast]].
    private static func confusions(_ errors: [(tap: Tap, meant: String)]) -> [[Any]] {
        var counts: [String: (Int, Int)] = [:]
        for error in errors {
            let pair = error.meant + error.tap.key
            let c = counts[pair] ?? (0, 0)
            counts[pair] = (c.0 + 1, c.1 + ((error.tap.interval ?? 9) < fast ? 1 : 0))
        }
        return counts.sorted { $0.value.0 > $1.value.0 }.prefix(12).map { pair, c in
            [String(pair.first!), String(pair.last!), c.0, Double(c.1) / Double(c.0)]
        }
    }

    /// Typos by how fast the tap came after the one before: [[label, taps, typos per 100 taps]].
    private static func tempo(_ taps: [Tap], _ errors: [(tap: Tap, meant: String)]) -> [[Any]] {
        let bands: [(String, Double, Double)] = [("<0.15 s", 0, 0.15), ("0.15–0.25", 0.15, 0.25), ("0.25–0.35", 0.25, 0.35),
                                                  ("0.35–0.6", 0.35, 0.6), (">0.6 s", 0.6, 1e9)]
        return bands.map { label, lo, hi in
            let inBand = { (t: Tap) in (t.interval ?? 9) >= lo && (t.interval ?? 9) < hi }
            let n = taps.filter(inBand).count, e = errors.filter { inBand($0.tap) }.count
            return [label, n, n > 0 ? Double(e) * 100 / Double(n) : 0]
        }
    }

    /// Release to text, counted in bands, per device: {device: [[label, count]]}.
    private static func latency(_ dayNames: Set<String>) -> [String: [[Any]]] {
        let bands: [(String, Double)] = [("<0.5", 0.5), ("0.5–1", 1), ("1–1.5", 1.5), ("1.5–2", 2), ("2–3", 3), ("3–5", 5), (">5", 1e9)]
        var counts: [String: [Int]] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dayNames.contains(String(dir.lastPathComponent.prefix(10))) {
            let d = latencyDigests.value(for: dir.appendingPathComponent("session.json")) { url in
                guard let data = try? Data(contentsOf: url),
                      let s = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let seconds = s["seconds"] as? Double, !((s["text"] as? String) ?? "").isEmpty else { return Heard() }
                return Heard(seconds: seconds, phone: s["device"] as? String == "iPhone")
            }
            guard let seconds = d.seconds else { continue }
            let device = d.phone ? "iPhone" : "Mac"
            let band = bands.firstIndex { seconds < $0.1 } ?? bands.count - 1
            counts[device, default: Array(repeating: 0, count: bands.count)][band] += 1
        }
        return counts.mapValues { c in zip(bands, c).map { [$0.0.0, $0.1] } }
    }

    /// Words whisper heard unsure (probability under 0.5) most often, with how often it heard
    /// them at all: [[word, unsure, all]].
    private static func unsure(_ dayNames: Set<String>) -> [[Any]] {
        var total: [String: (unsure: Int, all: Int)] = [:]
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? []
        for dir in dirs where dayNames.contains(String(dir.lastPathComponent.prefix(10))) {
            let counted = unsureDigests.value(for: dir.appendingPathComponent("listen-auto.json")) { url in
                var words: [String: [Int]] = [:]
                if let data = try? Data(contentsOf: url),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    // Whisper's pieces (the Mac's server: inside the segments), a word beginning at each
                    // piece led by a space; a word as sure as its least sure piece.
                    let pieces = (json["segments"] as? [[String: Any]] ?? []).flatMap { $0["words"] as? [[String: Any]] ?? [] }
                        + (json["words"] as? [[String: Any]] ?? [])
                    var current = "", least = 1.0
                    func finish() {
                        let word = current.lowercased().trimmingCharacters(in: .letters.inverted)
                        if word.count >= 3 {
                            let w = words[word] ?? [0, 0]
                            words[word] = [w[0] + (least < 0.5 ? 1 : 0), w[1] + 1]
                        }
                        current = ""
                        least = 1
                    }
                    for piece in pieces {
                        let text = piece["word"] as? String ?? ""
                        if text.hasPrefix(" ") || text.first.map({ !$0.isLetter }) == true { finish() }
                        current += text
                        least = min(least, piece["probability"] as? Double ?? 1)
                    }
                    finish()
                }
                return Heard(words: words)
            }.words
            for (word, c) in counted {
                let t = total[word] ?? (0, 0)
                total[word] = (t.unsure + c[0], t.all + c[1])
            }
        }
        // Words often heard and only now and then unsure ("это", 4%) say nothing; a tenth or more does.
        return total.filter { $0.value.unsure >= 3 && $0.value.unsure * 10 >= $0.value.all }
            .sorted { ($0.value.unsure, $0.key) > ($1.value.unsure, $1.key) }
            .prefix(24).map { [$0.key, $0.value.unsure, $0.value.all] }
    }

    /// How the phone was held, run of typing by run (taps under a second apart, ten or more): one
    /// finger's tip touches small, thumbs touch large — a quarter of the touches small is a finger,
    /// hardly any is thumbs. Thumbs also gain from alternating hands: two taps on one half come
    /// slower than a change of half. Each group's numbers, for checking that the two agree.
    private static func classifyPostures(_ taps: inout [Tap], width: Double) -> [String: Any] {
        var runs: [[Int]] = []
        var current: [Int] = []
        for i in taps.indices {
            if let last = current.last, taps[i].run != taps[last].run || taps[i].t - taps[last].t > 1 {
                if current.count >= 10 { runs.append(current) }
                current = []
            }
            current.append(i)
        }
        if current.count >= 10 { runs.append(current) }
        var stats: [String: (runs: Int, taps: Int, intervals: [Double], ratios: [Double], left: [Double], right: [Double])] = [:]
        for run in runs {
            let radii = run.compactMap { taps[$0].radius }
            guard radii.count >= 8 else { continue }
            let small = Double(radii.filter { $0 < 18 }.count) / Double(radii.count)
            guard let name = small >= 0.25 ? "finger" : small <= 0.08 ? "thumbs" : nil else { continue }
            for i in run { taps[i].posture = name }
            var same: [Double] = [], cross: [Double] = []
            for (a, b) in zip(run, run.dropFirst()) {
                let dt = taps[b].t - taps[a].t
                guard dt > 0.03, dt < 0.8 else { continue }
                if (taps[a].x < width / 2) == (taps[b].x < width / 2) { same.append(dt) } else { cross.append(dt) }
            }
            var s = stats[name] ?? (0, 0, [], [], [], [])
            s.runs += 1
            s.taps += run.count
            s.intervals += same + cross
            if same.count >= 4, cross.count >= 4, let ms = median(same), let mc = median(cross) { s.ratios.append(ms / mc) }
            stats[name] = s
        }
        return stats.mapValues { s in
            ["runs": s.runs, "taps": s.taps, "interval": median(s.intervals) ?? 0, "same_over_cross": median(s.ratios) ?? 0] as [String: Any]
        }
    }

    /// A keyboard minding where this user's finger lands on each key, typing fast: each tap given
    /// to the key of its row whose centre, moved by that key's offset (shrunk while few taps back
    /// it), is nearest. Counted on the fast taps: typos it would have turned into the letter meant,
    /// and taps typed right it would have turned wrong — with one set of offsets, and with each
    /// posture's own.
    private static func simulate(_ taps: [Tap], _ errors: [(tap: Tap, meant: String)], _ keys: [String: [Double]]) -> [String: Any] {
        let meant = Dictionary(errors.map { ("\($0.tap.run)|\($0.tap.t)", $0.meant) }) { a, _ in a }
        func run(_ offsetsFor: (Tap) -> [String: [Double]]) -> [String: Int] {
            var fixed = 0, broken = 0, still = 0
            for tap in taps {
                guard let k = keys[tap.key] else { continue }
                let table = offsetsFor(tap)
                let row = keys.filter { abs($0.value[1] - k[1]) < 1 }
                let chosen = row.min { a, b in
                    func d(_ e: (key: String, value: [Double])) -> Double {
                        let o = table[e.key] ?? [0, 0, 0]
                        let shrink = o[2] / (o[2] + 30)
                        return abs(tap.x - (e.value[0] + e.value[2] / 2 + o[0] * shrink))
                    }
                    return d(a) < d(b)
                }?.key ?? tap.key
                let wanted = meant["\(tap.run)|\(tap.t)"]
                if chosen == tap.key { continue }
                if let wanted { if chosen == wanted { fixed += 1 } else { still += 1 } } else { broken += 1 }
            }
            return ["fixed": fixed, "broken": broken, "moved_still_wrong": still]
        }
        let all = offsets(taps, keys)
        let thumbs = offsets(taps.filter { $0.posture == "thumbs" }, keys), finger = offsets(taps.filter { $0.posture == "finger" }, keys)
        return [
            "taps": taps.count,
            "typos": errors.filter { ($0.tap.interval ?? 9) < fast }.count,
            "one_set": run { _ in all },
            "per_posture": run { $0.posture == "finger" ? finger : $0.posture == "thumbs" ? thumbs : all },
        ]
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// A few plain sentences on what stands out.
    private static func findings(_ fastOffsets: [String: [Double]], _ keys: [String: [Double]],
                                 _ errors: [(tap: Tap, meant: String)], _ taps: [Tap],
                                 _ isFast: (Tap) -> Bool, _ isSlow: (Tap) -> Bool) -> [String] {
        var lines: [String] = []
        // The keys at each row's ends.
        var rows: [Double: [(String, Double)]] = [:]
        for (letter, k) in keys where k.count == 4 { rows[k[1], default: []].append((letter, k[0])) }
        var left: [Double] = [], right: [Double] = []
        for row in rows.values {
            let sorted = row.sorted { $0.1 < $1.1 }
            if let first = sorted.first, let dx = fastOffsets[first.0]?[0] { left.append(dx) }
            if let last = sorted.last, let dx = fastOffsets[last.0]?[0] { right.append(dx) }
        }
        let mean = { (v: [Double]) in v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        if mean(right) < -3 || mean(left) > 3 {
            lines.append(String(format: "Typing fast, the edges pull in: keys on the right edge land %.0f pt left of centre, on the left edge %.0f pt right.",
                                -mean(right), mean(left)))
        }
        let dy = mean(fastOffsets.values.map { $0[1] })
        if abs(dy) > 2 { lines.append(String(format: "Typing fast, taps land %.0f pt %@ the keys' centres.", abs(dy), dy > 0 ? "below" : "above")) }
        let fastTaps = taps.filter(isFast).count, slowTaps = taps.filter(isSlow).count
        let fastErrors = errors.filter { isFast($0.tap) }.count, slowErrors = errors.filter { isSlow($0.tap) }.count
        if fastTaps > 100, slowTaps > 30 {
            let fr = Double(fastErrors) / Double(fastTaps) * 100, sr = Double(slowErrors) / Double(slowTaps) * 100
            lines.append(String(format: "Typos: %.1f per 100 taps typing fast, %.1f typing slowly.", fr, sr))
        }
        if let top = confusions(errors).first, let meant = top.first as? String, let typed = top[1] as? String, let n = top[2] as? Int {
            lines.append("Most often typed for another: «\(typed)» for «\(meant)», \(n) times.")
        }
        return lines
    }
}
