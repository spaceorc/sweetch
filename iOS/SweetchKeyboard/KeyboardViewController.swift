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
        let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.spaceorc.sweetch")
        KeyLog.note("app-group", [
            "available": shared != nil,
            "app_wrote": shared.flatMap { try? String(contentsOf: $0.appendingPathComponent("from-app.txt"), encoding: .utf8) } ?? "",
        ])
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
        EmojiMemory.shared.reload()   // the app's Emoji screen may have changed it
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
    private var lastHeard: (text: String, at: Date, id: String?)?
    /// Dictations typed into this field, until the field is done with (sent, left): then each is
    /// found in the field again and logged as it ended up — what the user changed in it.
    private var inField: [(id: String?, text: String, at: Date)] = []
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
        // Text typed in incognito stays out of the log after it, lengths only.
        if incognitoResidue { return ["before_len": before.count, "has_text": proxy?.hasText ?? false, "residue": true] }
        return ["before": String(before.suffix(24)), "after": String(after.prefix(12)),
                "before_len": before.count, "has_text": proxy?.hasText ?? false]
    }

    private func log(_ event: String, _ fields: [String: Any] = [:]) {
        KeyLog.note(event, fields.merging(fieldState) { a, _ in a })
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    func appeared() {
        incognitoResidue = false
        // Before anything is noted: a private tab's field is incognito from its first moment.
        privateFieldDeclined = false
        privateField = looksPrivate()
        KeyLog.paused = incognito
        HostMemory.shared.paused = incognito
        showStatus()
        lastWord = nil
        visibleSince = Date()
        takeHeardOnPhone()
        deliverPending()
        startSession()
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
            // Everything else the field says of itself — what might tell a private tab, or a
            // sensitive field, apart.
            "spellcheck": proxy?.spellCheckingType?.rawValue ?? -1,
            "smart_quotes": proxy?.smartQuotesType?.rawValue ?? -1,
            "smart_dashes": proxy?.smartDashesType?.rawValue ?? -1,
            "smart_insert": proxy?.smartInsertDeleteType?.rawValue ?? -1,
            "inline_prediction": proxy?.inlinePredictionType?.rawValue ?? -1,
            "return_auto": proxy?.enablesReturnKeyAutomatically ?? false,
            "secure": proxy?.isSecureTextEntry ?? false,
            "has_text_at_appear": proxy?.hasText ?? false,
            "selected_len": proxy?.selectedText?.count ?? 0,
            "layout": "\(layout)", "shift": "\(shift)",
        ])
        listening?.cancel()
        KeyLog.paused = incognito
        HostMemory.shared.paused = incognito
        let here = incognito
        listening = Task { await listen(onlyHere: here) }
        autoCapitalise()
        fieldChanged()
    }

    func disappeared() {
        visibleSince = nil
        rememberField(now: true)
        // Gone a while with dictations in the field: as they stand. (Gone to the app's dictation
        // screen and back is not done with them.)
        if inField.contains(where: { Date().timeIntervalSince($0.at) > 600 }) { settleDictations(in: String(field.text), why: "away") }
        awaySince = Date()
        log("disappear")
        listening?.cancel()
        listening = nil
        Task { await KeyLog.flush() }
    }

    /// The host moved the cursor or changed the text.
    func hostChanged() {
        lastWord = nil   // the cursor moved or the text changed under it
        let previous = String(field.text)
        observeField()
        let now = String(field.text)
        if incognitoResidue {
            if now.isEmpty { incognitoResidue = false }   // sent or cleared: what's typed next is seen
        } else if now.isEmpty, !previous.isEmpty {
            // Emptied — a message sent — or only the focus leaving, when iOS shows an empty field a
            // moment before the keyboard goes: told apart by whether it's still up, and empty, then.
            HostMemory.shared.saw(previous, process: hostProcess)
            let since = visibleSince
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.visibleSince == since, since != nil, self.field.text.isEmpty else { return }
                self.settleDictations(in: previous, why: "emptied")
                self.noteExternal(from: previous, to: "")
            }
        } else {
            // Another field: what it held, before it's gone.
            if !now.hasPrefix(String(previous.prefix(20))) {
                HostMemory.shared.saw(previous, process: hostProcess)
                settleDictations(in: previous, why: "other-field")
            }
            noteExternal(from: previous, to: now)
        }
        rememberField(now: false)
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
        offered = nil
        let typed = display(key)
        if typed.first?.isLetter == true {
            if let tap { wordTaps.append(tap) } else { wordTapsHold = false }
        }
        if !(typed.first?.isLetter ?? true) { noteWordEnd(typed) }
        // «?», «!» or «)» right after a dictation that ended with a period: the period was a guess,
        // and this is what the sentence ends with — it takes the period's place. Logged as what the
        // dictation should have ended with, to learn a question's intonation from.
        if "?!)".contains(typed), let heard = lastHeard, heard.text.hasSuffix("."),
           proxy?.documentContextBeforeInput?.hasSuffix(heard.text) == true {
            spaceIsOurs = false
            deleteBackward()
            insert(typed)
            log("heard-mark", ["mark": typed, "dictation": heard.id ?? "", "heard": heard.text])
            if shift == .once { shift = .off }
            afterTyping()
            return
        }
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
        offered = nil
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
        offered = nil
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
        offered = nil
        lastWord = nil
        if wordTaps.isEmpty { wordTapsHold = false } else { wordTaps.removeLast() }
        spaceIsOurs = false
        if undoAutoFix() {
            afterTyping()
            return
        }
        deleteBackward()
        tapsFreshAtWordStart()
        log("delete")
        afterTyping()
    }

    /// The field changed by someone other than the keyboard — another dictation streaming words in,
    /// a paste, the app itself (sending clears it): what came and what went, for the log. The
    /// keyboard's own changes are in what's known already, so they show no difference here.
    private func noteExternal(from previous: String, to now: String) {
        guard previous != now else { return }
        let a = Array(previous), b = Array(now)
        var start = 0
        while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
        var end = 0
        while end < a.count - start, end < b.count - start, a[a.count - 1 - end] == b[b.count - 1 - end] { end += 1 }
        let removed = String(a[start..<(a.count - end)]), added = String(b[start..<(b.count - end)])
        let kind = now.isEmpty ? "cleared" : removed.isEmpty ? "added" : added.isEmpty ? "removed" : "replaced"
        // Emoji put in from the system's emoji keyboard right after a word: that word's, next time.
        if kind == "added", !incognito, !incognitoResidue {
            let emoji = added.split(separator: " ").map(String.init).filter(Emoji.isEmoji)
            let head = String(b[..<start]).trimmingCharacters(in: .whitespaces)
            let word = String(head.reversed().prefix { $0.isLetter }.reversed())
            if !emoji.isEmpty, emoji.count == added.split(separator: " ").count, !word.isEmpty {
                for one in emoji { EmojiMemory.shared.typed(Emoji.base(of: one), after: word) }
            }
        }
        KeyLog.note("external", ["kind": kind, "added": String(added.prefix(2000)), "removed": String(removed.prefix(2000)),
                                 "at": start, "field_len": b.count, "session": fieldSession])
    }

    /// A word deleted back to where it began: the next one typed is all taps again, and goes to
    /// the decoder — the word typed afresh after a wrong one included.
    private func tapsFreshAtWordStart() {
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.last.map({ !$0.isLetter && $0 != "-" && $0 != "'" && $0 != "’" }) ?? true else { return }
        wordTaps = []
        wordTapsHold = true
    }

    /// The word before the cursor, with the spaces after it — what a long-held backspace deletes.
    func deleteWord() {
        lastWord = nil
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaces = before.reversed().prefix { $0.isWhitespace }.count
        let word = before.dropLast(spaces).reversed().prefix { !$0.isWhitespace }.count
        for _ in 0..<max(spaces + word, 1) { deleteBackward() }
        tapsFreshAtWordStart()
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
    private var rememberedAt = Date.distantPast

    /// The field as now known, into the app's memory — at most every few seconds while typing.
    private func rememberField(now: Bool) {
        guard !incognito, !incognitoResidue else { return }
        guard now || Date().timeIntervalSince(rememberedAt) > 5 else { return }
        rememberedAt = Date()
        HostMemory.shared.saw(String(field.text), process: hostProcess)
    }

    /// Everything the keyboard knows of where the user is about to dictate, for the app's dictation:
    /// the field around the cursor, what kind of field it is, the way of writing, the words typed
    /// lately, and what it saw in this app before — other fields, earlier dictations. The far side
    /// picks what helps.
    private func dictationContext() -> [String: Any] {
        // Text typed in incognito isn't the dictation's to know.
        guard !incognitoResidue else { return ["layout": "\(letters)"] }
        let text = field.text
        let cursor = min(max(field.cursor, 0), text.count)
        var before = String(text[..<cursor]), after = String(text[cursor...])
        if text.isEmpty {
            before = proxy?.documentContextBeforeInput ?? ""
            after = proxy?.documentContextAfterInput ?? ""
        }
        var context: [String: Any] = [
            "field_before": String(before.suffix(4000)),
            "field_after": String(after.prefix(1500)),
            "recent_words": recentWords.suffix(60).joined(separator: " "),
            "layout": "\(letters)",
            "keyboard_type": proxy?.keyboardType?.rawValue ?? -1,
            "return_type": proxy?.returnKeyType?.rawValue ?? -1,
            "content_type": proxy?.textContentType?.rawValue ?? "",
        ]
        if let process = hostProcess { context["process"] = Int(process) }
        if let host = HostMemory.shared.host(hostProcess) {
            let now = Date()
            let current = String(text).trimmingCharacters(in: .whitespacesAndNewlines)
            let seen = { (items: [HostMemory.Seen]) in
                items.map { ["text": $0.text, "minutes_ago": Int(now.timeIntervalSince($0.at) / 60)] as [String: Any] }
            }
            // The field itself is sent apart; its record here would only repeat it.
            // The newest first, while they fit: a URL carries this to the app.
            var budget = 12_000
            let fields = host.fields.filter { $0.text != current }.reversed().prefix { field in
                budget -= field.text.count
                return budget >= 0
            }
            context["earlier_fields"] = seen(Array(fields.reversed()))
            context["earlier_dictations"] = seen(host.dictated)
        }
        return context
    }
    private var session: CursorSession?

    func setTrackpad(_ on: Bool) {
        lastWord = nil
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
        guard !incognito, !incognitoResidue else { return }
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
    /// What a tap on the emoji suggestion does: while a word is typed it takes the word's place;
    /// after the word is done (a space typed) it's added at the end.
    private enum EmojiUse { case replace, append }
    private var emojiUse: EmojiUse?
    /// The word the strip's emoji are for (what a pick is remembered under, what «not for this
    /// word» hides them for).
    private(set) var emojiWord: String?

    /// The emoji, as the last suggestion after two words, when the word being typed — or one of the
    /// first two suggestions for it — has one.
    private func withEmoji(_ words: [String], for asked: String) -> [String] {
        emojiUse = nil
        emojiWord = nil
        guard let (word, emoji) = ([asked] + words.prefix(2)).lazy
                .compactMap({ w -> (String, [String])? in let e = Emoji.ranked(for: w); return e.isEmpty ? nil : (w, e) }).first
        else { return words }
        emojiUse = .replace
        emojiWord = word
        return Array(words.prefix(2)) + [emoji.joined(separator: " ")]
    }

    /// After a word just finished: its emoji stays on the strip, beside the next word's predictions.
    private func emojiAfter(_ words: [String], previous: String?, before: String) -> [String] {
        emojiUse = nil
        emojiWord = nil
        guard let previous, before.hasSuffix(previous + " ") else { return words }
        let emoji = Emoji.ranked(for: previous)
        guard !emoji.isEmpty else { return words }
        emojiUse = .append
        emojiWord = previous
        return Array(words.prefix(2)) + [emoji.joined(separator: " ")]
    }

    /// The strip's long press on an emoji: a skin tone picked (remembered, and the emoji typed)…
    func chooseEmoji(_ toned: String) {
        if !incognito { EmojiMemory.shared.setTone(toned, for: Emoji.base(of: toned)) }
        choose(suggestion: toned)
    }

    /// …or the emoji never shown again: for this word, or for any.
    func hideEmoji(_ emoji: String, forThisWord: Bool) {
        EmojiMemory.shared.hide(Emoji.base(of: emoji), for: forThisWord ? emojiWord : nil)
        log("emoji-hidden", ["emoji": Emoji.base(of: emoji), "word": forThisWord ? (emojiWord ?? "") : "*"])
        fieldChanged()
    }

    func choose(suggestion: String) {
        offered = nil
        if Emoji.isEmoji(suggestion), let use = emojiUse {
            emojiUse = nil
            if !incognito, let emojiWord { EmojiMemory.shared.pick(Emoji.base(of: suggestion), for: emojiWord) }
            if use == .replace {
                lastWord = nil
                wordTaps = []
                wordTapsHold = true
                for _ in word { deleteBackward() }
            }
            insert(suggestion + " ")
            log("choose", ["word": word, "suggestion": suggestion, "emoji": use == .replace ? "replace" : "append", "from": suggestionsFrom])
            spaceIsOurs = true
            lastSpaceAt = Date()
            afterTyping()
            return
        }
        lastWord = nil
        wordTaps = []
        wordTapsHold = true
        for _ in word { deleteBackward() }
        let next = proxy?.documentContextAfterInput?.first
        let spaced = next == nil || !(next!.isWhitespace || next!.isPunctuation)
        insert(spaced ? suggestion + " " : suggestion)
        log("choose", ["word": word, "suggestion": suggestion, "spaced": spaced, "from": suggestionsFrom])
        KeyLog.note("word", ["word": suggestion, "boundary": "suggestion", "session": fieldSession])
        wordSeen(suggestion)
        spaceIsOurs = spaced
        lastSpaceAt = Date()
        afterTyping()
    }

    /// The word just finished, as it ended up — what the user's taps were meant to make, unless
    /// they go back to it. The log's labels come from these and from corrections.
    private func noteWordEnd(_ boundary: String) {
        let before = proxy?.documentContextBeforeInput ?? ""
        var word = String(before.reversed().prefix { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }.reversed())
        let taps = wordTaps, hold = wordTapsHold, times = wordTapTimes
        let typed = word
        wordTaps = []
        wordTapsHold = true
        guard !word.isEmpty else {
            lastWord = nil
            return
        }
        let pending = pendingCorrection
        pendingCorrection = nil
        let tapped = hold && taps.count == word.filter(\.isLetter).count && taps.count >= 2
        if tapped { shadowDecode(word, taps: taps) }
        // An English contraction typed without its apostrophe («im», «Ill»): what it is, ahead of
        // the decoder — unless the user took it back before.
        let contraction = (keepAsTyped[word.lowercased()] ?? 0) < 1 ? Apostrophes.fix(word) : nil
        if tapped, contraction == nil, pending?.word != word {   // not worked out by the space
            KeyLog.note("autocorrect-late", ["word": word])
            correctLate(word, taps: taps, boundary: boundary, before: before)
        }
        if let fixed = contraction {
            for _ in word { deleteBackward() }
            insert(fixed)
            log("autofix", ["typed": word, "fixed": fixed])
            autoFixed = AutoFix(typed: word, fixed: fixed, boundary: boundary, taps: hold ? taps : [], times: times)
            word = fixed
        // The decoder's correction, worked out while the word was typed: put in, and the strip offers
        // to take it back (so does ⌫ next).
        } else if tapped, let pending, pending.word == word, let fixed = pending.fixed, fixed != word {
            for _ in word { deleteBackward() }
            insert(fixed)
            log("autocorrect", ["typed": word, "fixed": fixed, "confidence": Double(pending.confidence)])
            autoFixed = AutoFix(typed: word, fixed: fixed, boundary: boundary, taps: hold ? taps : [], times: times)
            word = fixed
        } else if !word.contains("-"), let fixed = Hyphens.fix(word) {
            // A word written with a hyphen, typed without one: put right, and ⌫ next puts it back.
            for _ in word { deleteBackward() }
            insert(fixed)
            log("autofix", ["typed": word, "fixed": fixed])
            autoFixed = AutoFix(typed: word, fixed: fixed, boundary: boundary)
            word = fixed
        }
        if tapped, let pending, pending.word == typed, contraction == nil,
           autoFixed == nil || (autoFixed?.typed == typed && autoFixed?.fixed == pending.fixed) {
            offer(pending.alternatives, for: word, typed: typed, boundary: boundary, fixed: autoFixed != nil)
        }
        if tapped, contraction == nil, taps.count >= 3, (offered?.alternatives.count ?? 0) < 2 {
            offerWithOneTapOut(word: word, typed: typed, taps: taps, boundary: boundary, before: before)
        }
        // The word before, looked at again now that this one follows it.
        if tapped, autoFixed == nil, offered == nil, let last = lastWord { lookAgain(at: last, next: word, boundary: boundary, before: before) }
        lastWord = nil
        if tapped {
            let gaps = zip(times, times.dropFirst()).map { $1.timeIntervalSince($0) }.sorted()
            lastWord = LastWord(standing: word, boundary: boundary, taps: taps,
                                previous: previousWord(before: String(before.dropLast(word.count))),
                                fast: !gaps.isEmpty && gaps[gaps.count / 2] < 0.35, endedAt: Date())
        }
        KeyLog.note("word", ["word": word, "boundary": boundary, "session": fieldSession])
        wordSeen(word)
        if !incognito {
            recentWords.append(word)
            if recentWords.count > 100 { recentWords.removeFirst(recentWords.count - 100) }
        }
        rememberField(now: false)
    }

    /// The taps that typed the word being typed, in order — while they're all there is to it (no
    /// letter typed some other way, no cursor moved off the end).
    private var wordTaps: [WordDecoder.Tap] = [] {
        didSet {
            if wordTaps.count > oldValue.count { wordTapTimes.append(Date()) } else { wordTapTimes = Array(wordTapTimes.prefix(wordTaps.count)) }
        }
    }
    private var wordTapsHold = true
    /// When each of `wordTaps` came.
    private var wordTapTimes: [Date] = []

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

    /// What a word's taps put right, if anything: the decoder's correction, unless the word as typed
    /// is one the system knows or the user kept. On `decoderQueue`.
    private static func correction(of asked: String, taps: [WordDecoder.Tap], decoder: WordDecoder,
                                   context: WordDecoder.Context, keep: [String: Double]) -> (String?, Float, [String]) {
        let exact = decoder.decode(taps, context: context)
        var fixed = exact.correction
        // A word the user took corrections back from needs a surer one: each take-back raises the
        // bar (fading over weeks) — a signal, not a ban.
        let bar = decoder.threshold + 0.12 * Float(keep[asked.lowercased()] ?? 0)
        if fixed != nil, exact.confidence < bar || systemKnows(asked) { fixed = nil }
        if let word = fixed, asked.first?.isUppercase == true { fixed = word.prefix(1).uppercased() + word.dropFirst() }
        // The runners-up: near enough the best to have been it (the replay's `--alternatives`: of
        // the typos the user put right by hand, a third were among them, while they'd show after
        // 7% of the words that went in right).
        var alternatives: [String] = []
        if let best = exact.candidates.first?.cost {
            for c in exact.candidates where c.cost - best <= alternativeGap {
                let w = asked.first?.isUppercase == true ? c.word.prefix(1).uppercased() + c.word.dropFirst() : c.word
                guard w.lowercased() != asked.lowercased(), w.lowercased() != fixed?.lowercased(),
                      !alternatives.contains(where: { $0.lowercased() == w.lowercased() }) else { continue }
                alternatives.append(w)
                if alternatives.count == 2 { break }
            }
        }
        return (fixed, exact.confidence, alternatives)
    }

    /// How near the best a candidate must be to be offered after the word ends.
    static let alternativeGap: Float = 0.1

    /// The word decoded again with each tap taken out in turn — one struck by accident, which the
    /// search itself lets go («грюлубже», «сдлюелал», «кюесли»): the best of them offered too, when
    /// near the decoder's best with an extra tap's cost added (the replay's `--drop-one 0.72`: the
    /// word meant for 12 of the 139 that went in wrong, an offer after 1.4% of those that went in
    /// right). Once the word has ended: a decode for each of its taps is too much on every letter.
    private func offerWithOneTapOut(word: String, typed: String, taps: [WordDecoder.Tap], boundary: String, before: String) {
        let previous = previousWord(before: String(before.dropLast(typed.count)))
        let recent = recentWords
        let fixed = autoFixed != nil
        Self.decoderQueue.async { [weak self] in
            guard let decoder = Self.loadDecoder() else { return }
            let context = Self.context(previous, recent: recent, lexicon: decoder.lexicon)
            guard let best = decoder.decode(taps, context: context).candidates.first?.cost else { return }
            var found: (word: String, cost: Float)?
            for drop in taps.indices {
                var fewer = taps
                fewer.remove(at: drop)
                guard let c = decoder.decode(fewer, context: context).candidates.first,
                      c.cost + decoder.costs.insertion - best <= Self.alternativeGap,
                      found == nil || c.cost < found!.cost else { continue }
                found = (c.word, c.cost)
            }
            guard var alternative = found?.word else { return }
            if typed.first?.isUppercase == true { alternative = alternative.prefix(1).uppercased() + alternative.dropFirst() }
            DispatchQueue.main.async {
                guard let self, alternative.lowercased() != word.lowercased(), alternative.lowercased() != typed.lowercased(),
                      (self.proxy?.documentContextBeforeInput ?? "").hasSuffix(word + boundary) else { return }
                if let offered = self.offered {
                    guard offered.word == word, !offered.alternatives.contains(where: { $0.lowercased() == alternative.lowercased() }) else { return }
                    self.offer(offered.alternatives + [alternative], for: word, typed: typed, boundary: boundary, fixed: offered.fixed)
                } else {
                    guard self.word.isEmpty else { return }
                    self.offer([alternative], for: word, typed: typed, boundary: boundary, fixed: fixed)
                }
            }
        }
    }

    /// A word ended before its correction was worked out — fast typing, a short word: worked out
    /// now, and put in — also when the next word has been begun meanwhile, which stays as typed.
    private func correctLate(_ word: String, taps: [WordDecoder.Tap], boundary: String, before: String) {
        let previous = previousWord(before: String(before.dropLast(word.count)))
        let recent = recentWords, keep = keepAsTyped
        Self.decoderQueue.async { [weak self] in
            guard let decoder = Self.loadDecoder() else { return }
            let context = Self.context(previous, recent: recent, lexicon: decoder.lexicon)
            let (fixed, confidence, alternatives) = Self.correction(of: word, taps: taps, decoder: decoder, context: context, keep: keep)
            DispatchQueue.main.async {
                guard let self else { return }
                if fixed == nil || fixed == word {
                    // Nothing put right: the runners-up, while the word is still the last thing typed.
                    if !alternatives.isEmpty, (self.proxy?.documentContextBeforeInput ?? "").hasSuffix(word + boundary) {
                        self.offer(alternatives, for: word, typed: word, boundary: boundary, fixed: false)
                    }
                    return
                }
                guard let fixed else { return }
                // What was typed after: letters of the next word at most.
                let now = self.proxy?.documentContextBeforeInput ?? ""
                let next = String(now.reversed().prefix { $0.isLetter }.reversed())
                guard now.dropLast(next.count).hasSuffix(word + boundary) else { return }
                for _ in 0..<(word.count + boundary.count + next.count) { self.deleteBackward() }
                self.insert(fixed + boundary + next)
                self.log("autocorrect", ["typed": word, "fixed": fixed, "confidence": Double(confidence), "late": true])
                self.autoFixed = AutoFix(typed: word, fixed: fixed, boundary: boundary, taps: taps)
                if next.isEmpty { self.offer(alternatives, for: fixed, typed: word, boundary: boundary, fixed: true) }
            }
        }
    }

    /// The word just finished, while the next may still change it: how it stands, the space or mark
    /// after it, its taps, the word before it, and whether it was typed fast.
    private struct LastWord {
        let standing: String
        let boundary: String
        let taps: [WordDecoder.Tap]
        let previous: (word: String?, sentenceStart: Bool)
        let fast: Bool
        let endedAt: Date
    }
    private var lastWord: LastWord?

    /// The previous word looked at again once the next is typed — typing fast, words in a run: its
    /// candidates rescored with how likely each is right before the next word, and the word changed
    /// when it was no word or the decoder doubted it, and the next word clearly backs another
    /// ("модно ли" → "можно ли"). Both words stay where the cursor left them; the strip offers the
    /// take-back, and ⌫ next puts it back. On the user's typing, 7 typos put right for 1 word
    /// made wrong (Tools/keyboard/replay `--post`).
    private func lookAgain(at last: LastWord, next: String, boundary: String, before: String) {
        guard last.fast, Date().timeIntervalSince(last.endedAt) < 3,
              before.hasSuffix(last.standing + last.boundary + next) else { return }
        let recent = recentWords, keep = keepAsTyped
        Self.decoderQueue.async { [weak self] in
            guard let decoder = Self.loadDecoder(), let bigrams = decoder.bigrams,
                  let nextNode = decoder.lexicon.lookup(next.lowercased()) else { return }
            let context = Self.context(last.previous, recent: recent, lexicon: decoder.lexicon)
            let result = decoder.decode(last.taps, context: context)
            let standing = last.standing.lowercased()
            // Only a word the decoder left unsure, and none the user kept as typed.
            guard !result.literalIsWord || result.confidence > decoder.threshold * 0.5,
                  (keep[standing] ?? 0) == 0 else { return }
            let rescored = result.candidates.prefix(5).map { candidate -> (word: String, cost: Float, lift: Int) in
                let word = candidate.word.lowercased()
                let lift = decoder.lexicon.lookup(word).map { bigrams.weight(of: nextNode, after: $0) } ?? 0
                let f = Float(candidate.frequency)
                let lifted = lift > 0 ? min(255, f + Float(lift + 1) * (255 - f) / 16.5) : f
                return (word, candidate.cost - decoder.costs.language * (lifted - f) / 255, lift)
            }.sorted { $0.cost < $1.cost }
            guard let best = rescored.first, best.word != standing, best.lift >= 4 else { return }
            let fixed = last.standing.first?.isUppercase == true ? best.word.prefix(1).uppercased() + best.word.dropFirst() : best.word
            DispatchQueue.main.async {
                guard let self else { return }
                // Typed since: the space after the next word, letters of the one after at most.
                let tail = last.boundary + next + boundary
                let now = self.proxy?.documentContextBeforeInput ?? ""
                let more = String(now.reversed().prefix { $0.isLetter }.reversed())
                guard now.dropLast(more.count).hasSuffix(last.standing + tail) else { return }
                for _ in 0..<(last.standing.count + tail.count + more.count) { self.deleteBackward() }
                self.insert(fixed + tail + more)
                self.log("autocorrect", ["typed": last.standing, "fixed": fixed, "post": true, "next": next,
                                         "confidence": Double(result.confidence), "lift": best.lift])
                if more.isEmpty {
                    self.autoFixed = AutoFix(typed: last.standing, fixed: fixed, boundary: tail, kept: last.boundary + next)
                }
            }
        }
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
    /// A word put right: as typed, as fixed, and what follows it up to the cursor — the space or mark
    /// after it, and for a word looked at again once the next was typed, that next word too.
    /// `kept`: what of that ⌫ leaves in place when it takes the fix back.
    /// `taps`, `times`: the word's own taps, back with it when ⌫ takes the fix back — so the word
    /// edited after ("жтой" back, then "жтом") is the decoder's again.
    private struct AutoFix {
        let typed: String
        let fixed: String
        let boundary: String
        var kept = ""
        var taps: [WordDecoder.Tap] = []
        var times: [Date] = []
    }

    private var autoFixed: AutoFix? { didSet { changed() } }

    /// ⌫ right after a word was put right: the word as typed comes back, without the boundary, and
    /// with its taps. Not for a word looked at again once the next was typed: ⌫ there is for the
    /// next word ("Можно ли" — ⌫ to fix "ли" mustn't quietly bring "Модно" back); the strip's
    /// button takes that one back.
    private func undoAutoFix() -> Bool {
        guard let fix = autoFixed else { return false }
        autoFixed = nil
        guard fix.kept.isEmpty else { return false }
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.hasSuffix(fix.fixed + fix.boundary) else { return false }
        for _ in 0..<(fix.fixed.count + fix.boundary.count) { deleteBackward() }
        insert(fix.typed)
        log("autofix-undone", ["typed": fix.typed, "fixed": fix.fixed, "by": "delete"])
        keep(fix.typed)
        if !fix.taps.isEmpty, fix.taps.count == fix.typed.filter(\.isLetter).count {
            wordTaps = fix.taps
            wordTapTimes = fix.times.count == fix.taps.count ? fix.times : fix.taps.map { _ in Date.distantPast }
            wordTapsHold = true
        }
        return true
    }

    /// The strip's button: the word put back as typed, the space or mark after it kept.
    func revertAutoFix() {
        guard let fix = autoFixed else { return }
        autoFixed = nil
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.hasSuffix(fix.fixed + fix.boundary) else { return }
        for _ in 0..<(fix.fixed.count + fix.boundary.count) { deleteBackward() }
        insert(fix.typed + fix.boundary)
        log("autofix-undone", ["typed": fix.typed, "fixed": fix.fixed, "by": "button"])
        keep(fix.typed)
        afterTyping()
    }

    /// What the strip offers to take back: the word as it was typed.
    var revertOffer: String? { autoFixed?.typed }

    /// The decoder's runners-up for the word just ended, offered on the strip («→ word») until the
    /// next key: the word as it stands, as typed, the boundary after it, and whether it was put right.
    private struct Offered {
        let word: String
        let typed: String
        let boundary: String
        let fixed: Bool
        let alternatives: [String]
    }
    private var offered: Offered? { didSet { changed() } }

    /// What the strip offers instead of the word just ended.
    var alternativesOffer: [String] { offered?.alternatives ?? [] }

    private func offer(_ alternatives: [String], for word: String, typed: String, boundary: String, fixed: Bool) {
        guard !alternatives.isEmpty else { return }
        offered = Offered(word: word, typed: typed, boundary: boundary, fixed: fixed, alternatives: alternatives)
        log("alternatives", ["typed": typed, "word": word, "offered": alternatives, "fixed": fixed])
    }

    /// The strip's «→ word»: it takes the place of the word just ended, the boundary after it kept.
    func chooseAlternative(_ alternative: String) {
        guard let offer = offered else { return }
        offered = nil
        autoFixed = nil
        let before = proxy?.documentContextBeforeInput ?? ""
        guard before.hasSuffix(offer.word + offer.boundary) else { return }
        for _ in 0..<(offer.word.count + offer.boundary.count) { deleteBackward() }
        insert(alternative + offer.boundary)
        log("alternative-chosen", ["typed": offer.typed, "word": offer.word, "chosen": alternative,
                                   "rank": offer.alternatives.firstIndex(of: alternative) ?? -1, "fixed": offer.fixed])
        KeyLog.note("word", ["word": alternative, "boundary": "alternative", "session": fieldSession])
        wordSeen(alternative)
        afterTyping()
    }

    /// For the app's keyboard preview: the strip just after a correction.
    func previewCorrection(typed: String, fixed: String) { autoFixed = AutoFix(typed: typed, fixed: fixed, boundary: " ") }

    /// For the app's keyboard preview: the strip with the runners-up offered, after a correction or not.
    func previewAlternatives(typed: String, fixed: String?, alternatives: [String]) {
        if let fixed { autoFixed = AutoFix(typed: typed, fixed: fixed, boundary: " ") }
        offered = Offered(word: fixed ?? typed, typed: typed, boundary: " ", fixed: fixed != nil, alternatives: alternatives)
    }

    /// How often the user took a correction of each word back, fading by half every two weeks:
    /// [weight, when last] — it raises how sure a correction of that word must be.
    private var takenBack: [String: [Double]] = UserDefaults.standard.dictionary(forKey: "takenBack") as? [String: [Double]] ?? [:]
    private static let halfLife: Double = 14 * 24 * 3600

    /// The take-backs, faded to now.
    var keepAsTyped: [String: Double] {
        let now = Date().timeIntervalSince1970
        return takenBack.mapValues { $0[0] * pow(0.5, (now - $0[1]) / Self.halfLife) }.filter { $0.value > 0.05 }
    }

    private func keep(_ word: String) {
        guard !incognito else { return }
        let now = Date().timeIntervalSince1970
        let key = word.lowercased()
        let faded = takenBack[key].map { $0[0] * pow(0.5, (now - $0[1]) / Self.halfLife) } ?? 0
        takenBack[key] = [faded + 1, now]
        if takenBack.count > 1000 {
            takenBack = Dictionary(uniqueKeysWithValues: takenBack.sorted { $0.value[1] > $1.value[1] }.prefix(800).map { ($0.key, $0.value) })
        }
        UserDefaults.standard.set(takenBack, forKey: "takenBack")
    }

    /// The correction for the word being typed, if a space came now.
    private var pendingCorrection: (word: String, fixed: String?, confidence: Float, alternatives: [String])?

    /// Whether iOS's own dictionary knows the word, in the language of its letters — a word it
    /// knows isn't a typo, whatever the lexicon lacks («распознай»). Call on `decoderQueue`.
    nonisolated(unsafe) private static let checker = UITextChecker()
    private static func systemKnows(_ word: String) -> Bool {
        let cyrillic = word.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                             language: cyrillic ? "ru_RU" : "en_US").location == NSNotFound
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
            guard !incognito, !incognitoResidue else { return }
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
                    self.suggestions = self.emojiAfter(words, previous: previous.word, before: before)
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
        let keep = keepAsTyped
        if wordTapsHold, taps.count >= 2, taps.count == word.filter(\.isLetter).count, !Self.decoderFailed {
            let capital = word.first?.isUppercase == true
            Self.decoderQueue.async { [weak self] in
                guard let decoder = Self.loadDecoder() else { return }
                let context = Self.context(previous, recent: recent, lexicon: decoder.lexicon)
                let result = decoder.decode(taps, complete: true, context: context)
                // What a space would put right, worked out now so the space doesn't wait: the decoder's
                // correction, unless the word as typed is one the system knows or the user kept.
                let (fixed, confidence, alternatives) = Self.correction(of: asked, taps: taps, decoder: decoder, context: context, keep: keep)
                let words = result.candidates.map { capital ? $0.word.prefix(1).uppercased() + $0.word.dropFirst() : $0.word }
                var picked: [String] = []
                for candidate in words where !picked.contains(where: { $0.lowercased() == candidate.lowercased() }) {
                    picked.append(candidate)
                    if picked.count == 3 { break }
                }
                DispatchQueue.main.async {
                    guard let self, self.word == asked else { return }
                    self.pendingCorrection = (asked, fixed, confidence, alternatives)
                    self.suggestionsFrom = "decoder"
                    self.suggestions = self.withEmoji(picked.filter { $0.lowercased() != asked.lowercased() }.count > 0 ? picked : [], for: asked)
                }
            }
            return
        }
        Suggester.shared.suggest(for: asked) { [weak self] words, seconds in
            guard let self, self.word == asked else { return }
            if seconds > 0.05 { KeyLog.note("suggest-slow", ["ms": Int(seconds * 1000), "for": asked]) }
            self.suggestionsFrom = "dictionary"
            self.suggestions = self.withEmoji(words, for: asked)
        }
    }

    /// The words finished lately, likelier again (newest last). Kept across the keyboard's reloads
    /// (iOS makes it again for many a field) and restarts.
    private var recentWords: [String] {
        get { Self.recent }
        set {
            Self.recent = newValue
            UserDefaults.standard.set(newValue, forKey: "recentWords")
        }
    }
    private static var recent = UserDefaults.standard.stringArray(forKey: "recentWords") ?? []

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
        context.boosts = memory.boosts()
        return context
    }

    // MARK: The user's words

    /// This field's session, for the log.
    private var fieldSession = ""
    /// Used only on `decoderQueue`.
    nonisolated(unsafe) private static let memory = WordMemory()

    private func startSession() {
        fieldSession = String(UUID().uuidString.prefix(8))
    }

    /// A word finished: counted, to be lifted in the suggestions.
    private func wordSeen(_ word: String) {
        guard !incognito else { return }
        Self.decoderQueue.async {
            guard let decoder = Self.loadDecoder(), let node = decoder.lexicon.lookup(word) else { return }
            Self.memory.add(node)
        }
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
    /// `onlyHere`: incognito — the app on this phone only, no Mac.
    private func listen(onlyHere: Bool = false) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, addresses) in Server.macs.enumerated() where !onlyHere {
                group.addTask { await self.listen(to: addresses, first: index == 0) }
            }
            // And the app on this phone, which hears by itself when no Mac answers.
            group.addTask { await self.listen(to: [Server.thisPhone], first: false) }
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
                // The app on this phone not answering — suspended, perhaps, with what it heard
                // left in the app group.
                if mac == Server.thisPhone, UserDefaults.standard.object(forKey: Self.dictationOpenedKey) != nil {
                    takeHeardOnPhone()
                    deliverPending()
                }
                showStatus()
                try? await Task.sleep(for: .seconds(caughtUp ? 5 : 3))
                continue
            }
            connected[mac] = server
            do {
                let (next, text, id) = try await server.next(after: seq, wait: caughtUp ? 25 : 0)
                if Task.isCancelled { return }
                if next > seq, let text, !text.isEmpty {
                    let from = Server.name(of: mac)
                    if Self.dictationAwaited(heardAt: next) {
                        UserDefaults.standard.removeObject(forKey: Self.dictationOpenedKey)
                        UserDefaults.standard.set(["text": text, "at": Date().timeIntervalSince1970, "id": id ?? "", "from": from],
                                                  forKey: Self.pendingKey)
                        log("heard-pending", ["text": text, "dictation": id ?? "", "from": from])
                        deliverPending()
                    } else if caughtUp {
                        insertHeard(text, id: id, from: from, how: "live")
                    } else if last == nil {
                        last = text
                    }
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
        if incognito {
            status = privateField ? "private tab — nothing leaves the phone" : "incognito — nothing leaves the phone"
            return
        }
        let names = Server.macs.map(\.[0]).filter { connected[$0] != nil }.map(Server.name)
        // Short enough to fit: which Macs the keyboard hears from.
        status = names.isEmpty ? "○ no Mac in reach" : "● " + names.joined(separator: " · ")
    }

    /// With a space before it when the field's text runs right up to the cursor; the layout then
    /// follows the language of what was said.
    /// `again`: the pending dictation, typed once more into a field that lost it.
    /// `id`: the dictation's folder where it was heard (`from`); `how`: as it came while the keyboard
    /// was up ("live"), after the app's dictation screen ("after-app"), or the strip's button typing
    /// the last one again ("typed-again").
    private func insertHeard(_ text: String, again: Bool = false, id: String?, from: String, how: String) {
        wordTaps = []
        wordTapsHold = true
        // The same words from a second Mac: one that seemed gone while hearing, and the next heard
        // them again.
        if !again, how != "typed-again", let lastHeard, lastHeard.text == text, Date().timeIntervalSince(lastHeard.at) < 60 { return }
        lastHeard = (text, Date(), id)
        last = text
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
        insert(spaced)
        HostMemory.shared.dictated(text, process: hostProcess)
        log("heard", ["text": text, "dictation": id ?? "", "from": from, "how": how])
        if !incognito { inField.append((id, text, Date())) }
        let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        if latin + cyrillic > 0 {
            letters = latin > cyrillic ? .english : .russian
            layout = letters
        }
        afterTyping()
    }

    /// When the microphone last opened the app's dictation. The keyboard is gone meanwhile — the
    /// app is in front — so what's heard waits for it to come back, and the first poll then, which
    /// otherwise only catches up, types it.
    private static let dictationOpenedKey = "dictationOpenedAt"

    /// Heard (servers number their texts by the millisecond) after the microphone opened the
    /// dictation, not long ago.
    /// What the phone heard by itself, left in the app group: the dictation this keyboard opened,
    /// pending as if the app's loopback server had answered — which it may no longer, suspended —
    /// and that server's place moved past it, so it isn't typed twice.
    private func takeHeardOnPhone() {
        guard let heard = SharedState.takeHeard() else { return }
        UserDefaults.standard.set(max(heard.seq, UserDefaults.standard.integer(forKey: "lastSeq-\(Server.thisPhone)")),
                                  forKey: "lastSeq-\(Server.thisPhone)")
        guard Self.dictationAwaited(heardAt: heard.seq) else { return }
        UserDefaults.standard.removeObject(forKey: Self.dictationOpenedKey)
        UserDefaults.standard.set(["text": heard.text, "at": Date().timeIntervalSince1970, "id": heard.id ?? "", "from": "iPhone"],
                                  forKey: Self.pendingKey)
        log("heard-pending", ["text": heard.text, "dictation": heard.id ?? "", "from": "iPhone", "via": "app-group"])
    }

    private static func dictationAwaited(heardAt seq: Int) -> Bool {
        let opened = UserDefaults.standard.double(forKey: dictationOpenedKey)
        let heard = Double(seq) / 1000
        return opened > 0 && heard > opened && Date().timeIntervalSince1970 - opened < 300
    }

    /// What the dictation the microphone opened heard, until it's seen to stay in the field: back
    /// from the app, the host may make its field again a moment later — what was typed into the old
    /// one is gone, and iOS makes the keyboard again too.
    private static let pendingKey = "dictationPending"
    private var visibleSince: Date?

    /// The pending dictation typed once the keyboard has been up a moment, and checked a moment
    /// after; still pending if the field lost it — the next appearance types it again.
    private func deliverPending() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, let since = self.visibleSince, Date().timeIntervalSince(since) >= 0.6,
                  let pending = UserDefaults.standard.dictionary(forKey: Self.pendingKey),
                  let text = pending["text"] as? String else { return }
            if Date().timeIntervalSince1970 - (pending["at"] as? Double ?? 0) > 300 {
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
                return
            }
            // Typed once already: again only while the host may still be making its field anew — a
            // moment after. Later, the field showing less (focus moved away and back) is no loss.
            if let typedAt = pending["typed_at"] as? Double, Date().timeIntervalSince1970 - typedAt > 3 {
                UserDefaults.standard.removeObject(forKey: Self.pendingKey)
                self.log("heard-done", ["dictation": pending["id"] as? String ?? ""])
                return
            }
            let mark = String(text.suffix(24))
            if !(self.proxy?.documentContextBeforeInput ?? "").contains(mark) {
                var typed = pending
                if typed["typed_at"] == nil { typed["typed_at"] = Date().timeIntervalSince1970 }
                UserDefaults.standard.set(typed, forKey: Self.pendingKey)
                self.insertHeard(text, again: true, id: (pending["id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 from: pending["from"] as? String ?? "?", how: "after-app")
            }
            try? await Task.sleep(for: .milliseconds(1500))
            guard self.visibleSince == since else { return }
            let stayed = (self.proxy?.documentContextBeforeInput ?? "").contains(mark)
            self.log("heard-check", ["stayed": stayed])
            if stayed { UserDefaults.standard.removeObject(forKey: Self.pendingKey) }
        }
    }

    /// The app's dictation screen, opened from the strip's microphone: the app in front hears on the
    /// GPU, and what it hears comes back here (from a Mac, or from the app itself). A keyboard has
    /// no UIApplication to open URLs with; the responder chain reaches the host's application, or
    /// its scene, which takes its own options object.
    /// Incognito: the keyboard alone, on the phone. Nothing is logged, nothing learned (words,
    /// take-backs, field widths, what's typed in each app), nothing sent to a Mac — no
    /// field, no context, no dictation; correcting and suggesting go on, from what was learned
    /// before. Stays on until turned off.
    /// Turned on by hand: stays until turned off.
    private(set) var incognitoPicked = UserDefaults.standard.bool(forKey: "incognito") { didSet { changed(); share() } }
    /// A private field — Safari's private tab asks for a dark keyboard while the system is light —
    /// for as long as the keyboard is in it.
    private(set) var privateField = false { didSet { if privateField != oldValue { changed(); share() } } }
    /// The user turned incognito off in this private field: until the keyboard leaves it.
    private var privateFieldDeclined = false
    var incognito: Bool { incognitoPicked || privateField }
    /// The app learns of it too (SharedState): a dictation the Action Button starts now is incognito.
    private func share() { SharedState.keyboardIncognito = incognito }
    /// Incognito turned off with text in the field: what's in it was typed unseen, so the field's
    /// own changes (a send clearing it, what it held) stay unlogged and unremembered until it's
    /// emptied or another field comes — words typed from now on are logged as usual.
    private var incognitoResidue = false

    /// Safari, in a private tab, asks for a dark keyboard in its address and search fields while
    /// the system is light; a normal tab asks for a light one. Other traits are the same. In the
    /// dark system theme the two can't be told apart.
    private func looksPrivate() -> Bool {
        guard let proxy, proxy.keyboardAppearance == .dark,
              [.webSearch, .URL].contains(proxy.keyboardType ?? .default) else { return false }
        return UIScreen.main.traitCollection.userInterfaceStyle == .light
    }

    /// The strip's button: off when on (in a private tab, for this field), on by hand when off.
    func toggleIncognito() {
        if incognito {
            if privateField {
                privateFieldDeclined = true
                privateField = false
            }
            setIncognito(false)
        } else {
            setIncognito(true)
        }
    }

    func setIncognito(_ on: Bool) {
        let was = incognito
        if on, !was { KeyLog.note("incognito", ["on": true]) }   // the last thing logged
        incognitoPicked = on
        UserDefaults.standard.set(on, forKey: "incognito")
        guard incognito != was else { return }
        KeyLog.paused = incognito
        HostMemory.shared.paused = incognito
        lastWord = nil
        if incognito {
            listening?.cancel()
            connected = [:]
            listening = Task { await listen(onlyHere: true) }
            showStatus()
        } else {
            incognitoResidue = proxy?.hasText == true || !field.text.isEmpty
            KeyLog.note("incognito", ["on": false])
            showStatus()
            listening?.cancel()
            listening = Task { await listen() }
        }
    }

    func openDictation() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.dictationOpenedKey)
        observeField()
        rememberField(now: true)
        var components = URLComponents(string: "sweetch://dictate")!
        if incognito {
            // Heard on the phone alone, with nothing of the field.
            components.queryItems = [URLQueryItem(name: "incognito", value: "1")]
        } else {
            let context = dictationContext()
            KeyLog.note("open-dictation", ["context_keys": Array(context.keys).sorted()])
            if let json = try? JSONSerialization.data(withJSONObject: context) {
                components.queryItems = [URLQueryItem(name: "context", value: json.base64EncodedString())]
            }
        }
        guard let url = components.url else { return }
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        typealias Open = @convention(c) (AnyObject, Selector, URL, AnyObject?, AnyObject?) -> Void
        var responder: UIResponder? = controller
        var scene: UIResponder?
        while let current = responder {
            if NSStringFromClass(Swift.type(of: current)).contains("Application"), current.responds(to: selector) {
                unsafeBitCast(current.method(for: selector), to: Open.self)(current, selector, url, NSDictionary(), nil)
                return
            }
            if scene == nil, current is UIScene, current.responds(to: selector) { scene = current }
            responder = current.next
        }
        if let scene, let options = (NSClassFromString("UISceneOpenExternalURLOptions") as? NSObject.Type)?.init() {
            unsafeBitCast(scene.method(for: selector), to: Open.self)(scene, selector, url, options, nil)
            return
        }
        status = "open Sweetch to dictate"
    }

    func typeLast() {
        guard let last else { return }
        let id = lastHeard?.id
        lastHeard = nil
        insertHeard(last, id: id, from: "keyboard", how: "typed-again")
    }

    /// The field done with — emptied (a message sent), another field, the keyboard gone a while:
    /// each dictation typed into it, as the field holds it now (`dictation-final`). Its words are
    /// lined up with the field's (the longest common run), and the stretch between the first and
    /// the last matched word is what the dictation became.
    private func settleDictations(in text: String, why: String) {
        guard !inField.isEmpty else { return }
        let fieldWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        for dictation in inField {
            let heardWords = dictation.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let span = Self.matchedSpan(heardWords, in: fieldWords)
            let final = span.map { fieldWords[$0].joined(separator: " ") } ?? ""
            KeyLog.note("dictation-final", [
                "dictation": dictation.id ?? "", "heard": dictation.text, "final": final,
                "changed": final != dictation.text, "found": span != nil, "why": why,
                "seconds": Int(Date().timeIntervalSince(dictation.at)), "session": fieldSession,
            ])
        }
        inField = []
    }

    /// Where `heard` stands in `field`: the range of field words from the first to the last word
    /// matched by their longest common subsequence — nil when under a third of it is there.
    private static func matchedSpan(_ heard: [String], in field: [String]) -> ClosedRange<Int>? {
        guard !heard.isEmpty, !field.isEmpty else { return nil }
        let key = { (w: String) in w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let h = heard.map(key), f = field.map(key)
        var table = Array(repeating: Array(repeating: 0, count: f.count + 1), count: h.count + 1)
        for i in stride(from: h.count - 1, through: 0, by: -1) {
            for j in stride(from: f.count - 1, through: 0, by: -1) {
                table[i][j] = h[i] == f[j] && !h[i].isEmpty ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0
        var matched: [Int] = []
        while i < h.count, j < f.count {
            if h[i] == f[j], !h[i].isEmpty {
                matched.append(j)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        guard let first = matched.first, let last = matched.last, matched.count * 3 >= h.count else { return nil }
        return first...last
    }
}
