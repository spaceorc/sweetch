import Cocoa

/// A word of a dictation, clicked in the field it went into: a small menu by it of what it could be
/// instead, and a click on one puts that in its place. First what's at hand — what the other
/// listenings heard in its place, the user's own words that sound like it, its other forms — then,
/// a second or two later, the model's guesses: the rest of the text taken as right, the context and
/// every recogniser's version as when it was settled (Sonnet). On the user's own corrections that
/// offered the word they put in for 36 of 49 (Tools/dictation/alternatives.py, `--fill-probe`).
///
/// Only in what sweetch typed in the last quarter of an hour, in the app it went to, while the field
/// still holds it; a key or a click elsewhere closes it. Each choice is kept beside the dictation
/// (`corrections.jsonl`: heard → chosen) and noted in the typing log — what the settling can learn.
final class WordMenu: NSObject {
    static let shared = WordMenu()

    private struct Dictated {
        let dir: URL
        let text: String
        let pid: pid_t
        let at: Date
    }

    private let lock = NSLock()
    private var recent: [Dictated] = []
    private static let fresh: TimeInterval = 15 * 60
    private var panel: NSPanel?
    private var stack: NSStackView?
    private var shown: (word: String, element: AXUIElement, range: NSRange, dir: URL, offers: [(String, String)])?
    private var generation = 0

    /// sweetch typed `text` — or an app's own dictation wrote it, heard by us too — into `pid`'s field.
    func inserted(dir: URL, text: String, pid: pid_t) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lock.withLock {
            recent.append(Dictated(dir: dir, text: text, pid: pid, at: Date()))
            recent.removeAll { Date().timeIntervalSince($0.at) > Self.fresh }
        }
    }

    // MARK: Clicked

    /// A click, from the event tap: if it fell inside the menu, the menu's own; otherwise the menu
    /// goes, and once the app has moved its cursor, a word of a dictation under it gets one.
    func mouseDown() {
        if let panel, panel.isVisible, panel.frame.contains(NSEvent.mouseLocation) { return }
        hide()
        guard UserDefaults.standard.object(forKey: "wordMenu") as? Bool ?? true else { return }
        let hasRecent = lock.withLock { recent.contains { Date().timeIntervalSince($0.at) < Self.fresh } }
        guard hasRecent else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.lookAtCursor() }
    }

    /// Escape while the menu is up: it closes the menu, and nothing else — the app doesn't get it
    /// (a chat would close). From the event tap; true: eaten.
    func takeEscape(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
        return MainQueue.sync {
            guard panel?.isVisible == true else { return false }
            hide()
            TypingLog.shared.note("word-menu-closed", ["by": "escape"])
            return true
        }
    }

    /// A key pressed: the menu goes.
    func keyDown() {
        guard panel?.isVisible == true else { return }
        hide()
    }

    private func lookAtCursor() {
        guard let element = AX.focusedElement() else { return }
        AXUIElementSetMessagingTimeout(element, 0.2)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let candidates = lock.withLock { recent.filter { $0.pid == pid && Date().timeIntervalSince($0.at) < Self.fresh } }
        guard !candidates.isEmpty, let value = AX.string(element, kAXValueAttribute),
              let selection = AX.range(element, kAXSelectedTextRangeAttribute) else { return }
        let ns = value as NSString
        let isWordChar: (unichar) -> Bool = { c in
            guard let scalar = Unicode.Scalar(c) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || c == 0x2D || c == 0x27 || c == 0x5F
        }
        for dictated in candidates.reversed() {
            let found = ns.range(of: dictated.text, options: .backwards)
            guard found.location != NSNotFound,
                  selection.location >= found.location, selection.location + selection.length <= NSMaxRange(found) else { continue }
            var start = selection.location, end = selection.location + selection.length
            while start > found.location, isWordChar(ns.character(at: start - 1)) { start -= 1 }
            while end < NSMaxRange(found), isWordChar(ns.character(at: end)) { end += 1 }
            guard end > start else { return }
            let range = NSRange(location: start, length: end - start)
            let word = ns.substring(with: range)
            let at = start - found.location
            let offers = instantOffers(word: word, in: dictated, at: at)
            DispatchQueue.main.async { self.show(word: word, element: element, range: range, dir: dictated.dir, offers: offers) }
            askModel(word: word, dictated: dictated, at: at)
            return
        }
    }

    // MARK: What it could be

    private func instantOffers(word: String, in dictated: Dictated, at offset: Int) -> [(String, String)] {
        var offers: [(String, String)] = []
        func add(_ w: String, _ source: String) {
            guard !w.isEmpty, w.lowercased() != word.lowercased(),
                  !offers.contains(where: { $0.0.lowercased() == w.lowercased() }) else { return }
            offers.append((w, source))
        }
        // What the other listenings heard in the same place.
        let session = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dictated.dir.appendingPathComponent("session.json")))) as? [String: Any]
        let typedWords = Self.words(dictated.text)
        let index = Self.words(String(dictated.text.prefix(offset))).count
        var heard: [String] = (session?["listenings"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        heard += session?["versions"] as? [String] ?? []
        for text in heard {
            if let span = Self.aligned(typedWords, at: index, in: Self.words(text)), span.split(separator: " ").count <= 2 { add(span, "heard") }
        }
        if let lexicon = Self.lexicon {
            for w in Self.soundsLike(word, lexicon: lexicon).prefix(3) { add(w, "yours") }
            for w in Self.forms(of: word, lexicon: lexicon).prefix(3) { add(w, "forms") }
        }
        return Array(offers.prefix(6))
    }

    private func askModel(word: String, dictated: Dictated, at offset: Int) {
        guard LLMClient.isConfigured else { return }
        let session = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dictated.dir.appendingPathComponent("session.json")))) as? [String: Any]
        var context = (session?["settlement"] as? [String: Any])?["input"] as? String
        if context == nil {
            let versions = ((session?["versions"] as? [String]) ?? []).enumerated().map { "<version n=\"\($0.offset + 1)\">\($0.element)</version>" }
            let app = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: dictated.dir.appendingPathComponent("context.json")))) as? [String: Any])
            context = "<context><app>\(app?["app"] as? String ?? "")</app><window_title>\(app?["window_title"] as? String ?? "")</window_title></context>\n<versions>\n\(versions.joined(separator: "\n"))\n</versions>"
        }
        let ns = dictated.text as NSString
        let blanked = ns.replacingCharacters(in: NSRange(location: offset, length: (word as NSString).length), with: "[___]")
        let generation = lock.withLock { self.generation }
        Task {
            let started = Date()
            guard let reply = try? await LLMClient.complete(system: FillProbe.system, messages: [["role": "user", "content": """
                \(context ?? "")

                <final_text>\(blanked)</final_text>
                [___] stands for 1 word in the transcript (the filling may differ in length). The transcript had: «\(word)» — that is wrong.
                """]], maxTokens: 200, model: .smart, purpose: "word-menu") else { return }
            let options = LLMJSON.object(reply)?["options"] as? [String] ?? []
            TypingLog.shared.note("word-menu-model", ["seconds": Date().timeIntervalSince(started), "options": options.count])
            DispatchQueue.main.async {
                guard self.lock.withLock({ self.generation }) == generation else { return }
                self.append(options.map { ($0, "model") })
            }
        }
    }

    // MARK: The menu

    private func show(word: String, element: AXUIElement, range: NSRange, dir: URL, offers: [(String, String)]) {
        hide()
        lock.withLock { generation += 1 }
        shown = (word, element, range, dir, offers)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 40),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor), stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor), stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        panel.contentView = effect
        self.panel = panel
        self.stack = stack
        for offer in offers { addRow(offer) }
        let thinking = NSTextField(labelWithString: "…")
        thinking.textColor = .tertiaryLabelColor
        thinking.identifier = NSUserInterfaceItemIdentifier("thinking")
        stack.addArrangedSubview(thinking)
        place(element: element, range: range)
        panel.orderFrontRegardless()
        TypingLog.shared.note("word-menu", ["offers": offers.count, "sources": offers.map(\.1)])
    }

    private func addRow(_ offer: (String, String)) {
        guard let stack else { return }
        let button = NSButton(title: offer.0, target: self, action: #selector(choose(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = .labelColor
        button.font = .systemFont(ofSize: 14)
        button.identifier = NSUserInterfaceItemIdentifier(offer.1)
        button.toolTip = offer.1
        stack.addArrangedSubview(button)
    }

    /// The model's guesses, below what was offered already, the «…» gone.
    private func append(_ offers: [(String, String)]) {
        guard let stack, let shown, panel?.isVisible == true else { return }
        stack.arrangedSubviews.first { $0.identifier?.rawValue == "thinking" }?.removeFromSuperview()
        let have = Set(stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.title.lowercased() })
        for offer in offers.prefix(5) where !have.contains(offer.0.lowercased()) && offer.0.lowercased() != shown.word.lowercased() {
            addRow(offer)
        }
        self.shown?.offers += offers
        place(element: shown.element, range: shown.range)
    }

    /// Under the word, by where the field says it is.
    private func place(element: AXUIElement, range: NSRange) {
        guard let panel else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 40)
        var cfRange = CFRange(location: range.location, length: range.length)
        var bounds = CGRect(x: NSEvent.mouseLocation.x, y: 0, width: 0, height: 0)
        var topLeft = true
        if let value = AXValueCreate(.cfRange, &cfRange) {
            var result: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
               let result, CFGetTypeID(result) == AXValueGetTypeID() {
                AXValueGetValue(result as! AXValue, .cgRect, &bounds)
                // Electron (Claude, Slack) answers with an empty rectangle at the screen's corner.
                if bounds.width < 1 || bounds.height < 1 || (bounds.minX == 0 && bounds.minY == 0) { topLeft = false }
            } else { topLeft = false }
        } else { topLeft = false }
        // The word in Cocoa's coordinates (Accessibility's run down from the main screen's top).
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let word = topLeft
            ? NSRect(x: bounds.minX, y: screenHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            : NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 8, width: 1, height: 16)
        let width = max(size.width, 120)
        // Under the word if it fits above the Dock, over it otherwise; within the screen's visible part.
        let visible = (NSScreen.screens.first { $0.frame.contains(NSPoint(x: word.midX, y: word.midY)) } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 10_000, height: 10_000)
        var y = word.minY - size.height - 4
        if y < visible.minY { y = word.maxY + 4 }
        y = min(max(y, visible.minY), visible.maxY - size.height)
        let x = min(max(word.minX, visible.minX), visible.maxX - width)
        panel.setFrame(NSRect(x: x, y: y, width: width, height: size.height), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        stack = nil
        shown = nil
    }

    @objc private func choose(_ sender: NSButton) {
        guard let shown else { return }
        let replacement = sender.title
        let source = sender.identifier?.rawValue ?? "?"
        let rank = shown.offers.firstIndex { $0.0 == replacement } ?? -1
        hide()
        DispatchQueue.global(qos: .userInteractive).async {
            Self.replace(shown.element, shown.range, with: replacement)
        }
        TypingLog.shared.note("word-menu-chosen", ["source": source, "rank": rank])
        let record: [String: Any] = ["heard": shown.word, "chosen": replacement, "source": source,
                                     "at": DictationStore.stamp(Date())]
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            let url = shown.dir.appendingPathComponent("corrections.jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data + Data("\n".utf8)); try? handle.close()
            } else {
                try? (data + Data("\n".utf8)).write(to: url)
            }
        }
    }

    /// The word selected through Accessibility and typed over; where the field won't take a
    /// selection, the cursor walked to the word's end and the word deleted before typing.
    private static func replace(_ element: AXUIElement, _ range: NSRange, with text: String) {
        var cfRange = CFRange(location: range.location, length: range.length)
        var selected = false
        if let value = AXValueCreate(.cfRange, &cfRange),
           AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
            usleep(30_000)
            selected = AX.range(element, kAXSelectedTextRangeAttribute) == range
        }
        if !selected {
            let cursor = AX.range(element, kAXSelectedTextRangeAttribute)?.location ?? NSMaxRange(range)
            for _ in 0..<max(0, NSMaxRange(range) - cursor) { Replayer.postKeyPair(keyCode: 124, flags: []) }
            for _ in 0..<range.length { Replayer.postKeyPair(keyCode: 51, flags: []) }
        }
        usleep(20_000)
        Replayer.replace(deleteCount: 0, with: text)
    }

    // MARK: Words, sounds, forms

    private static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "'" || $0 == "_") }.map(String.init)
    }

    /// What `other` has where `typed` has its word at `index` (a longest-common-subsequence match).
    private static func aligned(_ typed: [String], at index: Int, in other: [String]) -> String? {
        guard index < typed.count else { return nil }
        let a = typed.map { $0.lowercased() }, b = other.map { $0.lowercased() }
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        // Walk the match; the words of `other` between the matches around `index` are its.
        var i = 0, j = 0, before = 0, after = b.count
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                if i < index { before = j + 1 } else if i > index { after = min(after, j); break }
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        guard before <= after else { return nil }
        let span = other[before..<after].joined(separator: " ")
        return span.lowercased() == typed[index].lowercased() || span.isEmpty ? nil : span
    }

    /// The user's words read from the lexicon, ahead of the first click (a second or two).
    static func prewarm() {
        DispatchQueue.global(qos: .utility).async { _ = own.count }
    }

    nonisolated(unsafe) private static var lexicon: Lexicon? = Bundle.main.url(forResource: "Lexicon", withExtension: "bin").flatMap(Lexicon.init)

    /// The user's own words (the lexicon's), by how they sound — made once, in the background.
    private static let own: [(key: String, word: String, frequency: Int)] = {
        guard let lexicon else { return [] }
        var out: [(String, String, Int)] = []
        var stack: [(Int, [UInt8])] = [(0, [])]
        while let (node, path) = stack.popLast() {
            if node != 0, lexicon.frequency(node) > 0, lexicon.flags(node) & 8 != 0 {
                let word = lexicon.word(path, node: node)
                out.append((sound(word), word, Int(lexicon.frequency(node))))
            }
            for child in lexicon.children(node) { stack.append((child, path + [lexicon.label(child)])) }
        }
        return out
    }()

    private static let translit: [Character: String] = {
        let cyr = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя")
        let lat = ["a", "b", "v", "g", "d", "e", "e", "zh", "z", "i", "y", "k", "l", "m", "n", "o", "p", "r", "s", "t",
                   "u", "f", "h", "ts", "ch", "sh", "sch", "", "y", "", "e", "yu", "ya"]
        return Dictionary(uniqueKeysWithValues: zip(cyr, lat))
    }()

    /// How a word sounds, roughly, Latin or Cyrillic: transliterated, vowels and doubled letters alike.
    static func sound(_ word: String) -> String {
        var s = word.lowercased().map { translit[$0] ?? String($0) }.joined()
        s = s.replacingOccurrences(of: "(.)\\1+", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[aeiouy]+", with: "a", options: .regularExpression)
        for (a, b) in [("dzh", "g"), ("zh", "g"), ("j", "g"), ("ph", "f"), ("ck", "k"), ("c", "k")] { s = s.replacingOccurrences(of: a, with: b) }
        return s
    }

    private static func soundsLike(_ word: String, lexicon: Lexicon) -> [String] {
        let key = sound(word)
        guard key.count >= 2 else { return [] }
        return own.compactMap { entry -> (String, Double)? in
            let d = distance(key, entry.key)
            let ratio = 1 - Double(d) / Double(max(key.count, entry.key.count))
            // Close, and starting with the same sound: the key is rough (all vowels one, «ч» near
            // «к»), and at 0.75 «четыре» drew «который» (23 Oct).
            return ratio >= 0.8 && entry.key.first == key.first && entry.word.lowercased() != word.lowercased()
                ? (entry.word, ratio * 1000 + Double(entry.frequency)) : nil
        }.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Other forms of a word: the lexicon's words that share all but its last letters, commonest first.
    private static func forms(of word: String, lexicon: Lexicon) -> [String] {
        let lower = word.lowercased()
        guard lower.count >= 4 else { return [] }
        let stem = String(lower.prefix(max(3, lower.count - 3)))
        var node = 0
        for c in stem {
            guard let l = lexicon.index(of: c), let next = lexicon.child(node, l) else { return [] }
            node = next
        }
        var found: [(String, Int)] = []
        var stack: [(Int, [UInt8], Int)] = [(node, stem.compactMap { lexicon.index(of: $0) }, 0)]
        while let (n, path, depth) = stack.popLast() {
            if lexicon.frequency(n) > 0, depth > 0 || n != node {
                let w = lexicon.word(path, node: n)
                if w.lowercased() != lower { found.append((w, Int(lexicon.frequency(n)) + (lexicon.flags(n) & 8 != 0 ? 40 : 0))) }
            }
            guard depth < 5 else { continue }
            for child in lexicon.children(n) { stack.append((child, path + [lexicon.label(child)], depth + 1)) }
        }
        if lexicon.frequency(node) > 0, stem != lower { found.append((lexicon.word(stem.compactMap { lexicon.index(of: $0) }, node: node), Int(lexicon.frequency(node)))) }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
