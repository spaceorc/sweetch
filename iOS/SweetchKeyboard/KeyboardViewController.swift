import UIKit

/// sweetch's keyboard: Russian, English, digits and symbols, made to feel like iOS's own — and where
/// what the Mac heard from an Action Button dictation is typed, as soon as it's heard. The layout
/// follows the language of it; the Mac is told what the field holds, for the prefix.
final class KeyboardViewController: UIInputViewController {
    private(set) lazy var model = KeyboardModel(controller: self)
    private let strip = KeyboardStrip()
    private lazy var surface = KeyboardSurface(model: model)
    private let stalls = StallWatch()

    override func loadView() {
        let view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        view.allowsSelfSizing = true
        self.view = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        KeyLog.note("load")
        strip.model = model
        for part in [strip, surface] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        let height = view.heightAnchor.constraint(equalToConstant: KeyboardStrip.height + KeyboardSurface.height)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: KeyboardStrip.height),
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: strip.bottomAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            height,
        ])
        surface.callouts = view
        model.changed = { [weak self] in
            self?.strip.render()
            self?.surface.render()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        surface.showsGlobe = needsInputModeSwitchKey
        model.appeared()
        stalls.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        if size != loggedSize {
            loggedSize = size
            KeyLog.note("size", ["w": KeyLog.round1(size.width), "h": KeyLog.round1(size.height)])
        }
    }
    private var loggedSize = CGSize.zero

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        KeyLog.note("memory-warning")
    }

    /// iOS holds back touches near the screen's edges, to see whether they're an edge swipe: the
    /// keys at the ends (backspace, shift) would act late. The window's recognizers stop holding them.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        var holder: UIView? = view
        while let current = holder {
            current.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
            holder = current.superview
        }
        view.window?.gestureRecognizers?.forEach { $0.delaysTouchesBegan = false }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stalls.stop()
        model.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.hostChanged()
    }

    override func selectionDidChange(_ textInput: UITextInput?) {
        super.selectionDidChange(textInput)
        KeyLog.note("selection-change", model.fieldState)
    }
}

/// Lets the keys click as iOS's own do, when the user has keyboard clicks on.
final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

@MainActor
final class KeyboardModel {
    enum Layout: Equatable {
        case russian, english, digits, symbols

        var rows: [String] {
            switch self {
            case .russian: ["йцукенгшщзх", "фывапролджэ", "ячсмитьбю"]
            case .english: ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
            case .digits: ["1234567890", "-/:;()₽&@\"", ".,?!'"]
            case .symbols: ["[]{}#%^*+=", "_\\|~<>€$£•", ".,?!'"]
            }
        }

        var isLetters: Bool { self == .russian || self == .english }
    }

    enum Shift { case off, once, locked }

    /// Called on every change the keys or the strip show.
    var changed: () -> Void = {}

    private(set) var layout: Layout = .russian {
        didSet {
            guard layout != oldValue else { return }
            KeyLog.note("layout", ["to": "\(layout)"])
            changed()
        }
    }
    /// The letters the digits go back to.
    private(set) var letters: Layout = .russian
    private(set) var shift: Shift = .once {
        didSet {
            guard shift != oldValue else { return }
            KeyLog.note("shift", ["to": "\(shift)"])
            changed()
        }
    }
    /// The space bar is held: the keys are a trackpad moving the cursor.
    private(set) var trackpad = false { didSet { if trackpad != oldValue { changed() } } }
    private(set) var status = "connecting…" {
        didSet {
            guard status != oldValue else { return }
            KeyLog.note("status", ["to": status])
            changed()
        }
    }
    private(set) var last: String? { didSet { if last != oldValue { changed() } } }
    /// Words the one being typed may be, from the system's dictionary.
    private(set) var suggestions: [String] = [] {
        didSet {
            guard suggestions != oldValue else { return }
            if !suggestions.isEmpty { KeyLog.note("suggestions", ["for": word, "words": suggestions]) }
            changed()
        }
    }

    private weak var controller: UIInputViewController?
    private var listening: Task<Void, Never>?
    private var fieldNote: Task<Void, Never>?
    /// The Macs the keyboard is waiting on, by Mac, as each answered.
    private var connected: [String: Server] = [:]
    private var lastHeard: (text: String, at: Date)?
    private var lastSpaceAt = Date.distantPast
    private var lastShiftAt = Date.distantPast
    private var word = ""
    private let checker = UITextChecker()
    private let lastSeqKey = "lastSeq"

    init(controller: UIInputViewController) {
        self.controller = controller
        KeyLog.deliver = { [weak self] batch in
            guard let self else { return false }
            for addresses in Server.macs {
                if let mac = connected[addresses[0]], await mac.keyboardLog(batch) { return true }
            }
            return false
        }
    }

    /// The field around the cursor, for the log: a little of it either side, and what the host says
    /// it is.
    var fieldState: [String: Any] {
        let before = proxy?.documentContextBeforeInput ?? ""
        let after = proxy?.documentContextAfterInput ?? ""
        return ["before": String(before.suffix(24)), "after": String(after.prefix(12)),
                "before_len": before.count, "has_text": proxy?.hasText ?? false]
    }

    private func log(_ event: String, _ fields: [String: Any] = [:]) {
        KeyLog.note(event, fields.merging(fieldState) { a, _ in a })
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    func appeared() {
        let proxy = proxy
        log("appear", [
            "keyboard_type": proxy?.keyboardType?.rawValue ?? -1,
            "return_type": proxy?.returnKeyType?.rawValue ?? -1,
            "autocap": proxy?.autocapitalizationType?.rawValue ?? -1,
            "autocorrect": proxy?.autocorrectionType?.rawValue ?? -1,
            "content_type": proxy?.textContentType?.rawValue ?? "",
            "appearance": proxy?.keyboardAppearance?.rawValue ?? -1,
            "layout": "\(layout)", "shift": "\(shift)",
        ])
        listening?.cancel()
        listening = Task { await listen() }
        autoCapitalise()
        fieldChanged()
    }

    func disappeared() {
        log("disappear")
        listening?.cancel()
        listening = nil
        Task { await KeyLog.flush() }
    }

    /// The host moved the cursor or changed the text.
    func hostChanged() {
        log("host-change")
        autoCapitalise()
        fieldChanged()
    }

    // MARK: Typing

    /// What a character key shows and types.
    func display(_ key: String) -> String {
        layout.isLetters && shift != .off ? key.uppercased() : key
    }

    func typeCharacter(_ key: String) {
        let typed = display(key)
        proxy?.insertText(typed)
        log("type", ["char": typed])
        if shift == .once { shift = .off }
        if !layout.isLetters, key == "'" {
            layout = letters   // as iOS does: after an apostrophe, back to the letters
        }
        fieldChanged()
    }

    /// A double space ends the sentence, as on iOS's own keyboard.
    func space() {
        let before = proxy?.documentContextBeforeInput ?? ""
        if Date().timeIntervalSince(lastSpaceAt) < 0.4, before.hasSuffix(" "), let previous = before.dropLast().last,
           previous.isLetter || previous.isNumber {
            proxy?.deleteBackward()
            proxy?.insertText(". ")
            lastSpaceAt = .distantPast
            log("space", ["period": true])
        } else {
            proxy?.insertText(" ")
            lastSpaceAt = Date()
            log("space")
        }
        if !layout.isLetters { layout = letters }
        afterTyping()
    }

    func newline() {
        guard returnKey.enabled else {
            log("return-disabled")
            return
        }
        proxy?.insertText("\n")
        log("return")
        afterTyping()
    }

    func backspace() {
        proxy?.deleteBackward()
        log("delete")
        afterTyping()
    }

    /// The word before the cursor, with the spaces after it — what a long-held backspace deletes.
    func deleteWord() {
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaces = before.reversed().prefix { $0.isWhitespace }.count
        let word = before.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<max(spaces + word, 1) { proxy?.deleteBackward() }
        log("delete-word", ["chars": max(spaces + word, 1)])
        afterTyping()
    }

    /// Shift acts as the finger touches it; a double tap locks the capitals.
    func shiftDown() {
        let now = Date()
        if now.timeIntervalSince(lastShiftAt) < 0.35, shift == .once {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftAt = now
    }

    /// Shift was held while a letter was typed: it was for that letter only.
    func shiftReleasedAfterTyping() {
        if shift != .locked { shift = .off }
    }

    func switchLanguage() {
        letters = letters == .russian ? .english : .russian
        layout = letters
        autoCapitalise()
    }

    func switchDigits() {
        layout = layout.isLetters ? .digits : letters
        if layout.isLetters { autoCapitalise() }
    }

    func switchSymbols() {
        layout = layout == .digits ? .symbols : .digits
    }

    func show(_ page: Layout) {
        layout = page
        if layout.isLetters { autoCapitalise() }
    }

    func nextKeyboard() {
        log("next-keyboard")
        controller?.advanceToNextInputMode()
    }

    func setTrackpad(_ on: Bool) { trackpad = on }

    func moveCursor(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
    }

    /// What the return key says: the field's own word for it, highlighted as iOS does.
    var returnKey: (title: String?, prominent: Bool, enabled: Bool) {
        let ru = letters == .russian
        let type = proxy?.returnKeyType ?? .default
        let title: String? = switch type {
        case .go: ru ? "Перейти" : "Go"
        case .google, .yahoo, .search: ru ? "Найти" : "Search"
        case .join: ru ? "Войти" : "Join"
        case .next, .continue: ru ? "Далее" : (type == .next ? "Next" : "Continue")
        case .route: ru ? "Маршрут" : "Route"
        case .send: ru ? "Отпр." : "Send"
        case .done: ru ? "Готово" : "Done"
        case .emergencyCall: ru ? "Экстр. вызов" : "Emergency"
        default: nil
        }
        let prominent = title != nil && type != .next && type != .continue
        let enabled = proxy?.enablesReturnKeyAutomatically != true || proxy?.hasText == true
        return (title, prominent, enabled)
    }

    func choose(suggestion: String) {
        for _ in word { proxy?.deleteBackward() }
        proxy?.insertText(suggestion + " ")
        log("choose", ["word": word, "suggestion": suggestion])
        lastSpaceAt = Date()
        afterTyping()
    }

    private func afterTyping() {
        autoCapitalise()
        fieldChanged()
    }

    /// A capital at the start of the field and of a sentence, where the field wants one.
    private func autoCapitalise() {
        guard shift != .locked, layout.isLetters else { return }
        guard proxy?.autocapitalizationType != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = proxy?.documentContextBeforeInput ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let sentenceStart = trimmed.isEmpty || (before.last?.isWhitespace == true && ".!?\n".contains(trimmed.last!))
            || before.hasSuffix("\n")
        shift = sentenceStart ? .once : .off
    }

    /// The suggestions for the word before the cursor, and the Mac told what the field holds —
    /// after the user pauses.
    private func fieldChanged() {
        suggest()
        fieldNote?.cancel()
        fieldNote = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let field = proxy?.documentContextBeforeInput ?? ""
            for mac in connected.values { await mac.noteField(field) }
        }
    }

    private func suggest() {
        let before = proxy?.documentContextBeforeInput ?? ""
        word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
        let insideWord = proxy?.documentContextAfterInput?.first?.isLetter == true
        guard !word.isEmpty, !insideWord else {
            suggestions = []
            return
        }
        let cyrillic = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let language = cyrillic ? "ru_RU" : "en_US"
        guard UITextChecker.availableLanguages.contains(language) else {
            suggestions = []
            return
        }
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
        suggestions = picked
    }

    // MARK: Dictation

    /// Waits on every Mac for what it hears next, and types it: a dictation goes to whichever Mac
    /// was reachable. What was heard before the keyboard came up isn't typed — it may have been
    /// meant for another field — but stays a tap away.
    private func listen() async {
        await withTaskGroup(of: Void.self) { group in
            for (index, addresses) in Server.macs.enumerated() {
                group.addTask { await self.listen(to: addresses, first: index == 0) }
            }
        }
    }

    private func listen(to addresses: [String], first: Bool) async {
        let mac = addresses[0]
        let seqKey = "lastSeq-\(mac)"
        // Earlier builds waited on one Mac, the first, and kept its place under one key.
        var seq = UserDefaults.standard.object(forKey: seqKey) as? Int
            ?? (first ? UserDefaults.standard.integer(forKey: lastSeqKey) : 0)
        var caughtUp = false
        while !Task.isCancelled {
            var found = connected[mac]
            if found == nil { found = await Server.answering(addresses) }
            guard let server = found else {
                connected[mac] = nil
                showStatus()
                try? await Task.sleep(for: .seconds(caughtUp ? 5 : 3))
                continue
            }
            connected[mac] = server
            do {
                let (next, text) = try await server.next(after: seq, wait: caughtUp ? 25 : 0)
                if Task.isCancelled { return }
                if next > seq, let text, !text.isEmpty {
                    if caughtUp { insertHeard(text) } else if last == nil { last = text }
                }
                seq = next
                UserDefaults.standard.set(seq, forKey: seqKey)
                if !caughtUp { fieldChanged() }   // the field, to the Mac just reached
                caughtUp = true
                showStatus()
            } catch {
                if Task.isCancelled { return }
                connected[mac] = nil
                showStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func showStatus() {
        let names = Server.macs.map(\.[0]).filter { connected[$0] != nil }.map(Server.name)
        status = names.isEmpty ? "no Mac in reach" : "ready · " + names.joined(separator: ", ") + " — hold the Action Button to dictate"
    }

    /// With a space before it when the field's text runs right up to the cursor; the layout then
    /// follows the language of what was said.
    private func insertHeard(_ text: String) {
        // The same words from a second Mac: one that seemed gone while hearing, and the next heard
        // them again.
        if let lastHeard, lastHeard.text == text, Date().timeIntervalSince(lastHeard.at) < 60 { return }
        lastHeard = (text, Date())
        last = text
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
        proxy?.insertText(spaced)
        log("heard", ["text": text])
        let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        if latin + cyrillic > 0 {
            letters = latin > cyrillic ? .english : .russian
            layout = letters
        }
        afterTyping()
    }

    func typeLast() {
        guard let last else { return }
        lastHeard = nil
        insertHeard(last)
    }
}
