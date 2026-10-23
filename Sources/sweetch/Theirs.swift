import ApplicationServices
import Foundation

/// What an app's own dictation wrote, for setting beside ours. The field is watched for a while
/// after release and every state it passed through is kept in `field.json`, so the text can be
/// read off again — `sweetch --theirs <dictation folder>…` — once the reading of it is improved.
enum Theirs {
    struct State {
        /// Seconds after the watch began.
        let at: TimeInterval
        let value: String
    }

    /// How long the field is watched: the app's dictation is done and the text usually sent by then.
    private static let watchSeconds: TimeInterval = 10

    /// Polls the focused field of `pid` until the user leaves the app or the time is up, writes what
    /// it saw to `field.json` in `dir`, and returns what the app wrote.
    /// `settled`: called once, as soon as what the app wrote has held still — for the word menu,
    /// which shouldn't wait the whole watch.
    static func watch(after before: String, in pid: pid_t, dir: URL, settled: ((String) -> Void)? = nil) -> String? {
        var states: [State] = []
        let started = Date()
        var told = false
        while Date().timeIntervalSince(started) < watchSeconds {
            usleep(400_000)
            guard let element = AX.focusedElement() else { continue }
            var owner: pid_t = 0
            AXUIElementGetPid(element, &owner)
            guard owner == pid else { break }   // the user moved on
            AXUIElementSetMessagingTimeout(element, 0.3)
            let value = AX.string(element, kAXValueAttribute) ?? ""
            if value != (states.last?.value ?? before) {
                states.append(State(at: Date().timeIntervalSince(started), value: value))
            }
            if !told, let settled, let last = states.last, Date().timeIntervalSince(started) - last.at >= 1.2,
               let written = extract(before: before, states: states, until: Date().timeIntervalSince(started)) {
                told = true
                settled(written)
            }
        }
        let until = Date().timeIntervalSince(started)
        DictationStore.write([
            "before": before, "until": until,
            "states": states.map { ["at": $0.at, "value": $0.value] },
        ], to: dir.appendingPathComponent("field.json"))
        return extract(before: before, states: states, until: until)
    }

    /// What went into the field after `before`: the insertion once the field has held still for
    /// 1.2 s (an app's dictation finishes writing a moment after release), or the last one before
    /// it was sent and emptied. In a terminal the "field" is the whole screen, which goes on
    /// changing after the text is sent — Claude Code's spinner, its answer — so there only its
    /// input box is read.
    static func extract(before screen: String, states: [State], until: TimeInterval) -> String? {
        let box = claudeCodeInput(screen)
        let before = box ?? screen
        var best: String?
        var last = before
        var lastAt: TimeInterval = 0
        for state in states {
            let now = box == nil ? state.value : claudeCodeInput(state.value) ?? ""
            if now == last { continue }
            if best != nil, state.at - lastAt >= 1.2 { return best }   // it held still
            if let inserted = insertion(from: before, to: now), !inserted.isEmpty { best = inserted }
            if best != nil, now.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return best }   // sent
            last = now
            lastAt = state.at
        }
        return best
    }

    /// `sweetch --theirs <dictation folder>…`: reads what the app wrote again, from `field.json`,
    /// and puts it in `session.json` when it came out differently.
    static func rerun(_ dirs: [URL]) {
        for dir in dirs {
            let field = json(dir.appendingPathComponent("field.json"))
            guard let before = field["before"] as? String else { continue }
            let states = (field["states"] as? [[String: Any]] ?? []).compactMap { s in
                (s["at"] as? Double).flatMap { at in (s["value"] as? String).map { State(at: at, value: $0) } }
            }
            let theirs = extract(before: before, states: states, until: field["until"] as? Double ?? 0)
            let url = dir.appendingPathComponent("session.json")
            var session = json(url)
            let was = session["theirs"] as? String
            guard was != theirs else { continue }
            print("\(dir.lastPathComponent)\n  was: \(was ?? "-")\n  now: \(theirs ?? "-")")
            session["theirs"] = theirs ?? NSNull()
            DictationStore.write(session, to: url)
        }
    }

    /// The text that went in between two states of a field: what's left once their common start and
    /// end are taken away.
    private static func insertion(from a: String, to b: String) -> String? {
        guard a != b else { return nil }
        let x = Array(a), y = Array(b)
        var start = 0
        while start < x.count, start < y.count, x[start] == y[start] { start += 1 }
        var endX = x.count, endY = y.count
        while endX > start, endY > start, x[endX - 1] == y[endY - 1] { endX -= 1; endY -= 1 }
        return withoutTerminalChrome(String(y[start..<endY]))
    }

    /// A terminal app redraws more than its input around what was dictated — Claude Code's
    /// separator rule, its status line with a ticking clock, its mode hint — and all of it lands in
    /// the difference. The input is what comes before the first rule; box-drawing borders go.
    private static func withoutTerminalChrome(_ text: String) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if isRule(line) {
                if !kept.joined().trimmingCharacters(in: .whitespaces).isEmpty { break }
                continue
            }
            kept.append(String(line.unicodeScalars.filter { !border.contains($0) }.map(Character.init)))
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^[>❯›]\\s*", with: "", options: .regularExpression)
    }

    /// What's typed in Claude Code's input box, read off a terminal's text: from the last `❯` prompt
    /// down to the rule under it, its wrapped lines put back together. Nil when there's no such box.
    /// iTerm2 gives blank cells as NULs.
    static func claudeCodeInput(_ screen: String) -> String? {
        let lines = screen.replacingOccurrences(of: "\0", with: " ").replacingOccurrences(of: "\u{a0}", with: " ")
            .components(separatedBy: .newlines)
        guard let top = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }) else { return nil }
        var typed: [String] = []
        for line in lines[top...] {
            if isRule(line) {
                return typed.joined(separator: " ").replacingOccurrences(of: "^❯\\s*", with: "", options: .regularExpression)
            }
            typed.append(line.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static let border = CharacterSet(charactersIn: "─━═│┃╭╮╰╯┌┐└┘├┤")

    /// A line drawn across: mostly box-drawing, perhaps with a label in it.
    private static func isRule(_ line: String) -> Bool {
        let glyphs = line.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        return glyphs.count >= 8 && Double(glyphs.filter(border.contains).count) > Double(glyphs.count) * 0.8
    }

    private static func json(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
}
