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
        EventSpy.install()
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
        var recognizers = EventSpy.recognizers(from: view)
        for recognizer in view.window?.gestureRecognizers ?? [] {
            recognizers.append("window/\(type(of: recognizer)) enabled:\(recognizer.isEnabled) delays:\(recognizer.delaysTouchesBegan) cancels:\(recognizer.cancelsTouchesInView)")
        }
        KeyLog.note("recognizers", ["list": recognizers])
        model.warmUp()
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
        model.observeField()
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
            if !suggestions.isEmpty { KeyLog.note("suggestions", ["for": word, "words": suggestions, "from": suggestionsFrom]) }
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
    /// The space after the word was the keyboard's (a suggestion picked), not the user's: a
    /// punctuation mark typed next goes before it, as on iOS.
    private var spaceIsOurs = false
    private var lastShiftAt = Date.distantPast
    private var word = ""
    private let lastSeqKey = "lastSeq"

    init(controller: UIInputViewController) {
        self.controller = controller
        KeyLog.deliver = { [weak self] events, batch in
            guard let self else { return false }
            for addresses in Server.macs {
                if let mac = connected[addresses[0]], await mac.keyboardLog(events, batch: batch) { return true }
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
        wordTaps = []
        wordTapsHold = true
        if let awaySince, Date().timeIntervalSince(awaySince) > 300 { field.forget() }
        awaySince = nil
        observeField()
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
        awaySince = Date()
        log("disappear")
        listening?.cancel()
        listening = nil
        Task { await KeyLog.flush() }
    }

    /// The host moved the cursor or changed the text.
    func hostChanged() {
        observeField()
        if !(proxy?.documentContextBeforeInput?.hasSuffix(" ") ?? false) { spaceIsOurs = false }
        log("host-change")
        autoCapitalise()
        fieldChanged()
    }

    // MARK: Typing

    /// What a character key shows and types.
    func display(_ key: String) -> String {
        layout.isLetters && shift != .off ? key.uppercased() : key
    }

    func typeCharacter(_ key: String, tap: WordDecoder.Tap? = nil) {
        autoFixed = nil
        let typed = display(key)
        if typed.first?.isLetter == true {
            if let tap { wordTaps.append(tap) } else { wordTapsHold = false }
        }
        if !(typed.first?.isLetter ?? true) { noteWordEnd(typed) }
        if spaceIsOurs, ".,!?:;".contains(typed), proxy?.documentContextBeforeInput?.hasSuffix(" ") == true {
            spaceIsOurs = false
            deleteBackward()
            insert(typed + " ")
            log("type", ["char": typed, "before_our_space": true])
            if !layout.isLetters { layout = letters }
            afterTyping()
            return
        }
        spaceIsOurs = false
        insert(typed)
        log("type", ["char": typed])
        if shift == .once { shift = .off }
        if !layout.isLetters, key == "'" {
            layout = letters   // as iOS does: after an apostrophe, back to the letters
        }
        fieldChanged()
    }

    /// A double space ends the sentence, as on iOS's own keyboard.
    /// How soon a second space must follow the first to end the sentence: the user's slower
    /// double taps (half a second and more) went unanswered at 0.4.
    static let doubleSpace: TimeInterval = 1.0
    /// What a sentence's last word may end with, for a double space to put a period after it.
    static let sentenceEnders = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: ")]}»\"'’”"))

    /// A double space ends the sentence, as on iOS's own keyboard. After a picked suggestion the
    /// space is already there: the user's first space only stands for it, and their second ends
    /// the sentence — not three spaces in a row.
    func space() {
        autoFixed = nil
        noteWordEnd(" ")
        let before = proxy?.documentContextBeforeInput ?? ""
        if spaceIsOurs, before.hasSuffix(" ") {
            spaceIsOurs = false
            lastSpaceAt = Date()
            log("space", ["absorbed": true])
            if !layout.isLetters { layout = letters }
            return
        }
        spaceIsOurs = false
        if Date().timeIntervalSince(lastSpaceAt) < Self.doubleSpace, before.hasSuffix(" "),
           let previous = before.dropLast().last, previous.unicodeScalars.allSatisfy(Self.sentenceEnders.contains) {
            deleteBackward()
            insert(". ")
            lastSpaceAt = .distantPast
            log("space", ["period": true])
        } else {
            insert(" ")
            lastSpaceAt = Date()
            log("space")
        }
        if !layout.isLetters { layout = letters }
        afterTyping()
    }

    func newline() {
        autoFixed = nil
        spaceIsOurs = false
        guard returnKey.enabled else {
            log("return-disabled")
            return
        }
        noteWordEnd("\n")
        insert("\n")
        log("return")
        afterTyping()
    }

    func backspace() {
        if wordTaps.isEmpty { wordTapsHold = false } else { wordTaps.removeLast() }
        spaceIsOurs = false
        if undoAutoFix() {
            afterTyping()
            return
        }
        deleteBackward()
        log("delete")
        afterTyping()
    }

    /// The word before the cursor, with the spaces after it — what a long-held backspace deletes.
    func deleteWord() {
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaces = before.reversed().prefix { $0.isWhitespace }.count
        let word = before.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<max(spaces + word, 1) { deleteBackward() }
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

    /// One trackpad session, for learning where the field wraps its lines: the text around the
    /// cursor as it began, where the cursor is in it (followed move by move, as iOS's report of
    /// the text lags behind), and the vertical moves made.
    private struct CursorSession {
        var text: String
        var index: Int
        var layout: TextLines    // the text wrapped as the field is taken to wrap it
        let width: CGFloat
        let guess: CGFloat
        let font: UIFont
        var start: Int?          // where the first move up or down began
        var lines = 0
        var landed: Int?         // where the model put the cursor after its last line
        var clamped = 0          // steps the model wanted too short or too long
        var blind = 0            // steps past the known text, by a line's characters
        var lost = false         // the cursor went past the known text: find it again
    }
    /// The field's text as pieced together so far.
    private let field = FieldText()

    /// Every change the keyboard makes goes through these, so what's known of the field follows
    /// it — iOS's view of the field may show only the sentence the cursor is in.
    private func insert(_ text: String) {
        proxy?.insertText(text)
        field.insert(text)
    }

    private func deleteBackward() {
        proxy?.deleteBackward()
        field.deleteBackward()
    }

    private func shiftCursor(by offset: Int) {
        proxy?.adjustTextPosition(byCharacterOffset: offset)
        field.moveCursor(by: offset)
    }

    /// What iOS shows of the field now, joined into what's known of it.
    func observeField() {
        field.observe(before: proxy?.documentContextBeforeInput ?? "", after: proxy?.documentContextAfterInput ?? "",
                      empty: proxy?.hasText == false)
    }
    /// When the keyboard last went away: what was learned of the field before a long absence may
    /// no longer be so — the text edited elsewhere, or another field altogether.
    private var awaySince: Date?
    private var session: CursorSession?

    func setTrackpad(_ on: Bool) {
        if on { wordTapsHold = false }   // the cursor's going elsewhere in the text
        trackpad = on
        if on {
            observeField()
            let text = String(field.text)
            let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: controller?.traitCollection)
            let guess = (controller?.view.window?.bounds.width ?? 440) - 40
            let width = FieldWidth.shared.width(for: hostProcess) ?? guess
            session = CursorSession(text: text, index: field.cursor,
                                    layout: TextLines(text, width: width, font: font),
                                    width: width, guess: guess, font: font)
        } else if let finished = session {
            session = nil
            noteCursorMove(finished)
        }
    }

    func moveCursor(by offset: Int) {
        shiftCursor(by: offset)
        if let current = session { session!.index = min(max(current.index + offset, 0), current.text.count) }
    }

    /// The app's process, which iOS does tell a keyboard: the same process is the same app, for as
    /// long as it runs — enough to learn a field's width per app.
    private lazy var hostProcess: Int32? = {
        guard let controller, controller.responds(to: NSSelectorFromString("_hostProcessIdentifier")),
              let pid = (controller.value(forKey: "_hostProcessIdentifier") as? NSNumber)?.int32Value, pid > 0
        else { return nil }
        return pid
    }()

    /// A move up or down finished, nudged sideways to where the user meant: logged with where the
    /// rule in use put the cursor and where the line model would have, at a guessed width and at
    /// the width learned so far — which this move then teaches. Nothing here moves the cursor.
    private func noteCursorMove(_ finished: CursorSession) {
        guard let start = finished.start, finished.lines != 0 else { return }
        let process = hostProcess
        // Wrapping text and fitting the width take a while: off the main thread.
        FieldWidth.shared.queue.async {
            let rule = Self.ruleLanding(finished.text, from: start, lines: finished.lines)
            let atGuess = TextLines(finished.text, width: finished.guess, font: finished.font).move(start, lines: finished.lines)
            let move = FieldWidth.Move(text: finished.text, start: start, lines: finished.lines, settled: finished.index,
                                       fontSize: finished.font.pointSize)
            let next = FieldWidth.shared.learn(move, process: process, font: finished.font, guess: finished.guess)
            DispatchQueue.main.async {
                KeyLog.note("cursor-move", [
                    "text": finished.text, "start": start, "lines": finished.lines, "settled": finished.index,
                    "model_used": finished.landed ?? -1, "width_used": KeyLog.round1(finished.width),
                    "clamped": finished.clamped, "blind": finished.blind, "text_len": finished.text.count,
                    "rule": rule, "model_guess": atGuess, "guess_width": KeyLog.round1(finished.guess),
                    "next_width": next.map { KeyLog.round1($0) } ?? -1,
                    "font_size": KeyLog.round1(finished.font.pointSize), "process": Int(process ?? 0),
                ])
            }
        }
    }

    /// How many characters a line of the field holds, taken as given: iOS doesn't tell a keyboard
    /// where the field wraps its lines, only the text around the cursor.
    static let lineLength = 40

    /// Up (negative) or down a line at a time, to the same place in it where there is one. Lines
    /// the user broke are found in the text; a long paragraph's wrapped lines are taken to be
    /// `lineLength` characters.
    /// Up (negative) or down a line, to the same distance from the line's start: the text around
    /// the cursor wrapped as the field is taken to wrap it (see TextLines). Without a session —
    /// never on the trackpad — the 40-character rule.
    func moveCursor(lines: Int) {
        guard let current = session else {
            let before = proxy?.documentContextBeforeInput ?? ""
            let after = proxy?.documentContextAfterInput ?? ""
            let offset = lines < 0 ? Self.lineUp(before: before) : Self.lineDown(before: before, after: after)
            if offset != 0 { shiftCursor(by: offset) }
            return
        }
        if current.start == nil { session!.start = current.index }
        // What iOS shows now may reach further than what was known: join it in, and wrap again.
        let shift = field.observe(before: proxy?.documentContextBeforeInput ?? "", after: proxy?.documentContextAfterInput ?? "",
                                  empty: proxy?.hasText == false)
        if String(field.text) != current.text {
            session!.text = String(field.text)
            session!.layout = TextLines(session!.text, width: current.width, font: current.font)
            if current.lost || shift == nil {
                session!.index = field.cursor   // iOS's word for where the cursor is
                session!.lost = false
            } else if let shift {
                session!.index = min(max(current.index + shift, 0), field.text.count)
            }
            if current.start != nil, let shift, shift > 0 { session!.start = current.start! + shift }
        }
        let now = session!
        let chars = now.layout.text
        // A line of this field in characters, about: the width over the text's mean letter.
        let mean = max(now.layout.totalWidth / CGFloat(max(chars.count, 1)), 4)
        let lineChars = max(Int((now.width / mean).rounded()), 8)
        var target = now.layout.move(now.index, lines: lines)
        var step = target - now.index
        let span = min(target, now.index)..<max(target, now.index)
        let crossesBreak = chars[span].contains("\n")
        if step == 0 {
            // At the edge of what's known: a line's characters, and find the cursor again after.
            step = lines < 0 ? -lineChars : lineChars
            session!.blind += 1
            session!.lost = true
        } else if !crossesBreak {
            // Within a paragraph a line is a line: no less than half one, no more than one and a half.
            let bounded = min(max(abs(step), lineChars / 2), lineChars * 3 / 2) * (step < 0 ? -1 : 1)
            if bounded != step {
                session!.clamped += 1
                step = bounded
            }
        }
        target = now.index + step
        shiftCursor(by: step)
        session!.index = target
        if target < 0 || target > chars.count { session!.lost = true }
        session!.index = min(max(target, 0), chars.count)
        session!.lines += lines
        session!.landed = session!.index
    }

    /// The 40-character rule's landing for a move, worked out on the text without moving: what the
    /// keyboard did before the line model, kept for comparing.
    static func ruleLanding(_ text: String, from start: Int, lines: Int) -> Int {
        let chars = Array(text)
        var index = start
        for _ in 0..<abs(lines) {
            let before = String(chars[..<index]), after = String(chars[index...])
            index = min(max(index + (lines < 0 ? lineUp(before: before) : lineDown(before: before, after: after)), 0), chars.count)
        }
        return index
    }

    static func lineUp(before: String) -> Int {
        let paragraphs = before.components(separatedBy: "\n")
        let current = paragraphs.last ?? ""
        let column = current.count % lineLength
        if current.count >= lineLength { return -lineLength }       // a wrapped line above, same paragraph
        guard paragraphs.count > 1 else { return -current.count }   // the very first line: its start
        let previous = paragraphs[paragraphs.count - 2]
        let lastRow = previous.count % lineLength == 0 && !previous.isEmpty ? lineLength : previous.count % lineLength
        // Back over this line's start and the line break, then to the same column of the line above.
        return -(current.count + 1 + max(lastRow - column, 0))
    }

    static func lineDown(before: String, after: String) -> Int {
        let current = before.components(separatedBy: "\n").last ?? ""
        let column = current.count % lineLength
        let rest = after.components(separatedBy: "\n")
        let leftInParagraph = rest.first?.count ?? 0
        if leftInParagraph > lineLength - column { return min(lineLength, leftInParagraph) }   // a wrapped line below
        guard rest.count > 1 else { return leftInParagraph }        // the very last line: its end
        let next = rest[1]
        return leftInParagraph + 1 + min(column, next.count)
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

    /// The word replaced by the suggestion, and a space after it — unless the text goes on right
    /// after it already (a word fixed in the middle of the text), where a space would be a second.
    func choose(suggestion: String) {
        wordTaps = []
        wordTapsHold = true
        for _ in word { deleteBackward() }
        let next = proxy?.documentContextAfterInput?.first
        let spaced = next == nil || !(next!.isWhitespace || next!.isPunctuation)
        insert(spaced ? suggestion + " " : suggestion)
        log("choose", ["word": word, "suggestion": suggestion, "spaced": spaced, "from": suggestionsFrom])
        KeyLog.note("word", ["word": suggestion, "boundary": "suggestion"])
        spaceIsOurs = spaced
        lastSpaceAt = Date()
        afterTyping()
    }

    /// The word just finished, as it ended up — what the user's taps were meant to make, unless
    /// they go back to it. The log's labels come from these and from corrections.
    private func noteWordEnd(_ boundary: String) {
        let before = proxy?.documentContextBeforeInput ?? ""
        var word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.reversed())
        let taps = wordTaps, hold = wordTapsHold
        wordTaps = []
        wordTapsHold = true
        guard !word.isEmpty else { return }
        if hold, taps.count == word.filter(\.isLetter).count, taps.count >= 2 { shadowDecode(word, taps: taps) }
        // A word written with a hyphen, typed without one: put right, and ⌫ next puts it back.
        if !word.contains("-"), let fixed = Hyphens.fix(word) {
            for _ in word { deleteBackward() }
            insert(fixed)
            log("autofix", ["typed": word, "fixed": fixed])
            autoFixed = (typed: word, fixed: fixed, boundary: boundary)
            word = fixed
        }
        KeyLog.note("word", ["word": word, "boundary": boundary])
        recentWords.append(word)
        if recentWords.count > 100 { recentWords.removeFirst(recentWords.count - 100) }
    }

    /// The taps that typed the word being typed, in order — while they're all there is to it (no
    /// letter typed some other way, no cursor moved off the end).
    private var wordTaps: [WordDecoder.Tap] = []
    private var wordTapsHold = true

    private static let decoderQueue = DispatchQueue(label: "sweetch.decoder", qos: .utility)
    nonisolated(unsafe) private static var decoder: WordDecoder?
    nonisolated(unsafe) private static var decoderFailed = false

    /// The decoder, in the shadow: what it would type for the word just finished is logged; the
    /// word stays as typed.
    /// The decoder, with its lexicon mapped in on first use. Call on `decoderQueue`.
    private static func loadDecoder() -> WordDecoder? {
        if decoder == nil, !decoderFailed {
            if let url = Bundle.main.url(forResource: "Lexicon", withExtension: "bin"), let lexicon = Lexicon(url: url) {
                let bigrams = Bundle.main.url(forResource: "Bigrams", withExtension: "bin").flatMap(Bigrams.init)
                decoder = WordDecoder(lexicon: lexicon, bigrams: bigrams)
            } else {
                decoderFailed = true
                DispatchQueue.main.async { KeyLog.note("decoder-missing") }
            }
        }
        return decoder
    }

    private func shadowDecode(_ word: String, taps: [WordDecoder.Tap]) {
        let previous = previousWord(before: proxy?.documentContextBeforeInput ?? "")
        let recent = recentWords
        Self.decoderQueue.async {
            guard let decoder = Self.loadDecoder() else { return }
            let started = Date()
            let result = decoder.decode(taps, context: Self.context(previous, recent: recent, lexicon: decoder.lexicon))
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async {
                KeyLog.note("decoder", [
                    "word": word, "literal": result.literal, "literal_is_word": result.literalIsWord,
                    "correction": result.correction ?? "", "confidence": Double(result.confidence),
                    "top": result.candidates.prefix(3).map(\.word), "taps": taps.count, "ms": ms,
                ])
            }
        }
    }

    /// The last word put right, while the next thing done may still be ⌫ taking it back.
    private var autoFixed: (typed: String, fixed: String, boundary: String)?

    /// ⌫ right after a word was put right: the word as typed comes back, without the boundary.
    private func undoAutoFix() -> Bool {
        guard let fix = autoFixed else { return false }
        autoFixed = nil
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.hasSuffix(fix.fixed + fix.boundary) else { return false }
        for _ in 0..<(fix.fixed.count + fix.boundary.count) { deleteBackward() }
        insert(fix.typed)
        log("autofix-undone", ["typed": fix.typed, "fixed": fix.fixed])
        return true
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

    /// Suggestions for the word being typed: the decoder's, from where the taps came down, when
    /// every letter of the word was a tap; the system dictionary's otherwise (and while the decoder
    /// isn't there). Worked out off the main thread; shown if the word is still the same.
    private func suggest() {
        let before = proxy?.documentContextBeforeInput ?? ""
        word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" }.reversed())
        let insideWord = proxy?.documentContextAfterInput?.first?.isLetter == true
        let previous = previousWord(before: before)
        let recent = recentWords
        // Before a letter of the next word: the words likeliest after the last one.
        if word.isEmpty, !insideWord, before.last?.isWhitespace == true, !Self.decoderFailed, !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let capital = previous.sentenceStart && proxy?.autocapitalizationType != UITextAutocapitalizationType.none
            Self.decoderQueue.async { [weak self] in
                guard let decoder = Self.loadDecoder() else { return }
                let words = decoder.predictions(Self.context(previous, recent: recent, lexicon: decoder.lexicon))
                    .map { capital ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
                DispatchQueue.main.async {
                    guard let self, self.word.isEmpty else { return }
                    self.suggestionsFrom = "prediction"
                    self.suggestions = words
                }
            }
            return
        }
        guard !word.isEmpty, !insideWord else {
            suggestions = []
            return
        }
        let asked = word
        let taps = wordTaps
        if wordTapsHold, taps.count >= 2, taps.count == word.filter(\.isLetter).count, !Self.decoderFailed {
            let capital = word.first?.isUppercase == true
            Self.decoderQueue.async { [weak self] in
                guard let decoder = Self.loadDecoder() else { return }
                let result = decoder.decode(taps, complete: true,
                                            context: Self.context(previous, recent: recent, lexicon: decoder.lexicon))
                let words = result.candidates.map { capital ? $0.word.prefix(1).uppercased() + $0.word.dropFirst() : $0.word }
                var picked: [String] = []
                for candidate in words where !picked.contains(where: { $0.lowercased() == candidate.lowercased() }) {
                    picked.append(candidate)
                    if picked.count == 3 { break }
                }
                DispatchQueue.main.async {
                    guard let self, self.word == asked else { return }
                    self.suggestionsFrom = "decoder"
                    self.suggestions = picked.filter { $0.lowercased() != asked.lowercased() }.count > 0 ? picked : []
                }
            }
            return
        }
        Suggester.shared.suggest(for: asked) { [weak self] words, seconds in
            guard let self, self.word == asked else { return }
            if seconds > 0.05 { KeyLog.note("suggest-slow", ["ms": Int(seconds * 1000), "for": asked]) }
            self.suggestionsFrom = "dictionary"
            self.suggestions = words
        }
    }

    /// The words finished lately, likelier again (newest last).
    private var recentWords: [String] = []

    /// The word before the one being typed, from the text before it — nil at a sentence's start.
    private func previousWord(before text: String) -> (word: String?, sentenceStart: Bool) {
        var rest = Substring(text)
        while let last = rest.last, last.isLetter || last == "'" || last == "’" || last == "-" { rest = rest.dropLast() }
        let gap = rest.reversed().prefix { !$0.isLetter && !$0.isNumber }
        let before = rest.dropLast(gap.count)
        if before.isEmpty || gap.contains(where: { ".!?…\n".contains($0) }) { return (nil, true) }
        let word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.reversed())
        return (word.isEmpty ? nil : word, false)
    }

    /// What the decoder is told of the text around the word: the word before, and the recent ones.
    private static func context(_ previous: (word: String?, sentenceStart: Bool), recent: [String],
                                lexicon: Lexicon) -> WordDecoder.Context {
        var context = WordDecoder.Context()
        if previous.sentenceStart { context.previous = 0 } else if let word = previous.word { context.previous = lexicon.lookup(word) }
        context.recent = Set(recent.compactMap { lexicon.lookup($0) })
        return context
    }

    /// Where the suggestions shown came from, for the log.
    private var suggestionsFrom = ""

    /// A tap that came down near another letter's key: whether the word would have picked that
    /// one instead — the start of the word with each letter, as the system dictionary knows it. The
    /// first letter of a word isn't judged: nothing comes before it. Logged only; it types as ever.
    func shadow(typed: String, other: String, gap: CGFloat, touch: Int, held: Int, travel: CGFloat) {
        let before = proxy?.documentContextBeforeInput ?? ""
        let prefix = String(before.reversed().prefix { $0.isLetter }.reversed())
        guard !prefix.isEmpty else { return }
        let typedStart = prefix + display(typed), otherStart = prefix + display(other)
        Suggester.shared.plausibility(of: [typedStart, otherStart]) { counts in
            let (typedN, otherN) = (counts[0], counts[1])
            let would = typedN == 0 && otherN > 0 ? other : typed
            KeyLog.note("shadow", [
                "touch": touch, "typed": typed, "other": other, "gap": KeyLog.round1(gap), "prefix": prefix,
                "typed_n": typedN, "other_n": otherN, "would": would, "held_ms": held, "travel": KeyLog.round1(travel),
            ])
        }
    }

    /// The dictionary loaded before the first key is touched.
    func warmUp() {
        Suggester.shared.warmUp()
        Self.decoderQueue.async { _ = Self.loadDecoder() }   // the lexicon mapped before the first word
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
        // Short enough to fit: which Macs the keyboard hears from.
        status = names.isEmpty ? "○ no Mac in reach" : "● " + names.joined(separator: " · ")
    }

    /// With a space before it when the field's text runs right up to the cursor; the layout then
    /// follows the language of what was said.
    private func insertHeard(_ text: String) {
        wordTaps = []
        wordTapsHold = true
        // The same words from a second Mac: one that seemed gone while hearing, and the next heard
        // them again.
        if let lastHeard, lastHeard.text == text, Date().timeIntervalSince(lastHeard.at) < 60 { return }
        lastHeard = (text, Date())
        last = text
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
        insert(spaced)
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
