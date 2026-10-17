import UIKit

/// A key: what it does, and where.
struct KeySpec: Equatable {
    enum Kind: Equatable {
        case character(String)
        case shift, backspace, more, symbols, language, globe, space, ret
    }

    let kind: Kind
    let frame: CGRect
    var alternates: [String] = []

    var character: String? {
        if case .character(let character) = kind { return character }
        return nil
    }
}

/// The keys, laid out as iOS lays out its own, and every touch on them. A key acts as the finger
/// lifts, and the next finger down commits the one still held (typing with two thumbs); a touch
/// between keys belongs to the nearest. A held key offers its alternates, a held space bar moves
/// the cursor, a held backspace deletes on — by words after a while.
final class KeyboardSurface: UIView {
    static let keyHeight: CGFloat = 46
    static let rowGap: CGFloat = 11
    static let gap: CGFloat = 6
    static let side: CGFloat = 3
    static let top: CGFloat = 4
    static let height = top + 4 * keyHeight + 3 * rowGap + 6
    /// A background touches land on, which no eye sees.
    static let touchable = UIColor(white: 0.5, alpha: 0.002)

    /// What a held key offers, as iOS's Russian and English keyboards do.
    static let alternates: [String: [String]] = [
        "е": ["ё"], "ь": ["ъ"],
        "e": ["é", "è", "ê", "ë"], "a": ["à", "á", "â", "ä", "æ"], "o": ["ó", "ò", "ô", "ö", "ø"],
        "u": ["ú", "ù", "û", "ü"], "i": ["í", "ì", "î", "ï"], "c": ["ç"], "n": ["ñ"], "s": ["ß"],
        "0": ["°"], "-": ["–", "—", "•"], "/": ["\\"], "₽": ["$", "€", "£", "¥"], "&": ["§"],
        ".": ["…"], "?": ["¿"], "!": ["¡"], "'": ["’", "‘", "`"], "\"": ["«", "»", "„", "“", "”"],
        "%": ["‰"], "=": ["≠", "≈"],
    ]

    private let model: KeyboardModel
    var showsGlobe = false {
        didSet { if showsGlobe != oldValue { built = nil; render() } }
    }
    /// Where callouts are drawn: over the strip too, as the top row's must be.
    weak var callouts: UIView?

    private var keys: [KeySpec] = []
    private var keyViews: [KeyView] = []
    private var built: (layout: KeyboardModel.Layout, width: CGFloat, globe: Bool)?
    private var presses: [UITouch: Press] = [:]

    init(model: KeyboardModel) {
        self.model = model
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        // Not clear: iOS hands a keyboard no touch where it's fully transparent — a finger landing
        // between keys was lost. Invisible, but there.
        backgroundColor = KeyboardSurface.touchable
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.render() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        render()
    }

    func render() {
        let width = bounds.width
        guard width > 0 else { return }
        if built?.layout != model.layout || built?.width != width || built?.globe != showsGlobe {
            keys = Self.layOut(model.layout, width: width, globe: showsGlobe)
            keyViews.forEach { $0.removeFromSuperview() }
            keyViews = keys.map { KeyView(spec: $0) }
            keyViews.forEach(addSubview)
            built = (model.layout, width, showsGlobe)
            // Where every key is: a touch can be measured against any of them later, not only the
            // one it went to.
            KeyLog.note("keys", ["layout": "\(model.layout)", "width": KeyLog.round1(width), "keys": keys.map {
                [KeyLog.name(of: $0.kind), KeyLog.round1($0.frame.minX), KeyLog.round1($0.frame.minY),
                 KeyLog.round1($0.frame.width), KeyLog.round1($0.frame.height)]
            }])
        }
        let held = Set(presses.values.map(\.key.frame.origin.debugDescription))
        for view in keyViews {
            view.show(model: model, pressed: held.contains(view.spec.frame.origin.debugDescription))
        }
    }

    // MARK: Layout

    static func layOut(_ layout: KeyboardModel.Layout, width: CGFloat, globe: Bool) -> [KeySpec] {
        let inner = width - 2 * side
        let ten = (inner - 9 * gap) / 10
        let rows = layout.rows.map { $0.map(String.init) }
        let unit = rows[0].count >= 11 ? (inner - 10 * gap) / 11 : ten
        func y(_ row: Int) -> CGFloat { top + CGFloat(row) * (keyHeight + rowGap) }
        func character(_ key: String, x: CGFloat, row: Int, width: CGFloat) -> KeySpec {
            KeySpec(kind: .character(key), frame: CGRect(x: x, y: y(row), width: width, height: keyHeight),
                    alternates: alternates[key] ?? [])
        }

        var keys: [KeySpec] = []
        for row in 0..<2 {
            let count = CGFloat(rows[row].count)
            var x = side + (inner - count * unit - (count - 1) * gap) / 2
            for key in rows[row] {
                keys.append(character(key, x: x, row: row, width: unit))
                x += unit + gap
            }
        }

        // The third row: shift (or the symbols' switch) and backspace at the ends, the keys between.
        let third = rows[2]
        let count = CGFloat(third.count)
        let end = layout == .russian ? unit : ten * 1.3
        let keyWidth = layout.isLetters ? unit : (inner - 2 * end - 2 * (2 * gap) - (count - 1) * gap) / count
        let left: KeySpec.Kind = layout.isLetters ? .shift : .symbols
        keys.append(KeySpec(kind: left, frame: CGRect(x: side, y: y(2), width: end, height: keyHeight)))
        var x = side + (inner - count * keyWidth - (count - 1) * gap) / 2
        for key in third {
            keys.append(character(key, x: x, row: 2, width: keyWidth))
            x += keyWidth + gap
        }
        keys.append(KeySpec(kind: .backspace, frame: CGRect(x: side + inner - end, y: y(2), width: end, height: keyHeight)))

        // The bottom row: what isn't the space bar has its width; the space bar takes the rest.
        var bottom: [(KeySpec.Kind, CGFloat?)] = [(.more, ten * 1.3)]
        if globe { bottom.append((.globe, ten * 1.1)) }
        bottom += [(.language, ten * 1.1), (.space, nil), (.ret, ten * 2.3)]
        let fixed = bottom.compactMap(\.1).reduce(0, +) + CGFloat(bottom.count - 1) * gap
        x = side
        for (kind, width) in bottom {
            let width = width ?? inner - fixed
            keys.append(KeySpec(kind: kind, frame: CGRect(x: x, y: y(3), width: width, height: keyHeight)))
            x += width + gap
        }
        return keys
    }

    /// The key a touch belongs to: the row by height, then the nearest key in it.
    private func key(at point: CGPoint) -> KeySpec? {
        let pitch = Self.keyHeight + Self.rowGap
        let row = min(3, max(0, Int(((point.y - Self.top + Self.rowGap / 2) / pitch).rounded(.down))))
        let rowY = Self.top + CGFloat(row) * pitch
        func distance(_ key: KeySpec) -> CGFloat {
            point.x < key.frame.minX ? key.frame.minX - point.x : max(point.x - key.frame.maxX, 0)
        }
        return keys.filter { abs($0.frame.minY - rowY) < 1 }.min { distance($0) < distance($1) }
    }

    // MARK: Touches

    private final class Press {
        var key: KeySpec
        var timer: Timer?
        var repeats = 0
        var callout: Callout?
        var alternates: Callout?
        var trackpadX: CGFloat?
        var carry: CGFloat = 0
        /// Shift held while a letter was typed.
        var typedWith = false
        /// The page before a page key was touched, and the one it showed.
        var pages: (from: KeyboardModel.Layout, to: KeyboardModel.Layout)?
        /// For the log: where and when the finger came down, and how far it wandered.
        let start: CGPoint
        let began = ProcessInfo.processInfo.systemUptime
        var travel: CGFloat = 0
        let touch: Int

        init(key: KeySpec, start: CGPoint, touch: Int) {
            self.key = key
            self.start = start
            self.touch = touch
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { noteIfSlow("began", since: started) }
        for touch in touches {
            let point = touch.location(in: self)
            var fields = KeyLog.touch(touch, in: self)
            fields["held"] = presses.count
            fields["all_touches"] = event?.allTouches?.count ?? 0
            guard let key = key(at: point) else {
                KeyLog.note("down-nokey", fields)
                continue
            }
            KeyLog.note("down", fields.merging(KeyLog.key(key, at: point)) { a, _ in a })
            // A new finger commits a character still held: two thumbs typing.
            for (other, press) in presses where press.key.character != nil && press.alternates == nil {
                presses[other] = nil
                KeyLog.note("rollover", ["touch": press.touch, "key": KeyLog.name(of: press.key.kind),
                                         "held_ms": Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000)])
                finish(press, at: nil)
            }
            let press = Press(key: key, start: point, touch: ObjectIdentifier(touch).hashValue & 0xFFFF)
            presses[touch] = press
            begin(press)
        }
        render()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let press = presses[touch] else { continue }
            let point = touch.location(in: self)
            press.travel = max(press.travel, hypot(point.x - press.start.x, point.y - press.start.y))
            if let alternates = press.alternates {
                let was = alternates.chosen
                alternates.select(at: convert(point, to: alternates.superview))
                if alternates.chosen != was { KeyLog.note("alternate", ["touch": press.touch, "chosen": alternates.chosen ?? -1]) }
            } else if let start = press.trackpadX {
                press.carry += point.x - start
                press.trackpadX = point.x
                let steps = Int(press.carry / 9)
                if steps != 0 {
                    KeyLog.note("trackpad", ["touch": press.touch, "steps": steps])
                    model.moveCursor(by: steps)
                    press.carry -= CGFloat(steps) * 9
                }
            } else if press.key.character != nil, let key = key(at: point), key.character != nil, key != press.key {
                // Sliding onto another key: that one is meant.
                KeyLog.note("slide", ["touch": press.touch, "from": KeyLog.name(of: press.key.kind)]
                    .merging(KeyLog.key(key, at: point)) { a, _ in a }.merging(KeyLog.touch(touch, in: self)) { a, _ in a })
                press.timer?.invalidate()
                press.callout?.removeFromSuperview()
                press.key = key
                begin(press, quietly: true)
                render()
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let started = ProcessInfo.processInfo.systemUptime
        defer { noteIfSlow("ended", since: started) }
        for touch in touches {
            let point = touch.location(in: self)
            guard let press = presses.removeValue(forKey: touch) else {
                KeyLog.note("up-untracked", KeyLog.touch(touch, in: self).merging(KeyLog.key(key(at: point), at: point)) { a, _ in a })
                continue
            }
            KeyLog.note("up", KeyLog.touch(touch, in: self)
                .merging(KeyLog.key(press.key, at: point)) { a, _ in a }
                .merging(KeyLog.key(key(at: point), at: point, prefix: "under")) { a, _ in a }
                .merging(["held_ms": Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000),
                          "travel": KeyLog.round1(press.travel)]) { a, _ in a })
            finish(press, at: point)
        }
        render()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let press = presses.removeValue(forKey: touch) else {
                KeyLog.note("cancel-untracked", KeyLog.touch(touch, in: self))
                continue
            }
            KeyLog.note("cancel", KeyLog.touch(touch, in: self)
                .merging(KeyLog.key(press.key, at: touch.location(in: self))) { a, _ in a }
                .merging(["held_ms": Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000),
                          "travel": KeyLog.round1(press.travel)]) { a, _ in a })
            press.timer?.invalidate()
            press.callout?.removeFromSuperview()
            press.alternates?.removeFromSuperview()
            if press.trackpadX != nil { model.setTrackpad(false) }
        }
        render()
    }

    /// A touch whose handling held the main thread long enough to delay the next one.
    private func noteIfSlow(_ phase: String, since started: TimeInterval) {
        let ms = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if ms > 8 { KeyLog.note("slow-handler", ["phase": phase, "ms": Int(ms)]) }
    }

    private func begin(_ press: Press, quietly: Bool = false) {
        if !quietly { UIDevice.current.playInputClick() }
        switch press.key.kind {
        case .character(let character):
            press.callout = showCallout(for: press.key, labels: [model.display(character)])
            if !press.key.alternates.isEmpty {
                press.timer = .scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self, weak press] _ in
                    MainActor.assumeIsolated {
                        guard let self, let press else { return }
                        press.callout?.removeFromSuperview()
                        press.callout = nil
                        let labels = [character] + press.key.alternates
                        press.alternates = self.showCallout(for: press.key, labels: labels.map(self.model.display), selected: 1)
                        KeyLog.note("alternates-shown", ["touch": press.touch, "key": character])
                    }
                }
            }
        case .shift:
            model.shiftDown()
        // The other keys' page shows as the finger touches, so it can slide on to one of them.
        case .more, .symbols:
            let from = model.layout
            if press.key.kind == .more { model.switchDigits() } else { model.switchSymbols() }
            press.pages = (from, model.layout)
        case .backspace:
            model.backspace()
            press.timer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak press] _ in
                MainActor.assumeIsolated {
                    guard let self, let press else { return }
                    press.repeats += 1
                    switch press.repeats {
                    case ..<5: break   // held half a second before repeating
                    case ..<25:
                        KeyLog.note("repeat", ["touch": press.touch, "n": press.repeats])
                        self.model.backspace()
                    default:
                        if press.repeats % 2 == 0 {
                            KeyLog.note("repeat-word", ["touch": press.touch, "n": press.repeats])
                            self.model.deleteWord()
                        }
                    }
                    UIDevice.current.playInputClick()
                }
            }
        case .space:
            press.timer = .scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self, weak press] _ in
                MainActor.assumeIsolated {
                    guard let self, let press, let touch = self.presses.first(where: { $0.value === press })?.key else { return }
                    press.trackpadX = touch.location(in: self).x
                    KeyLog.note("trackpad-on", ["touch": press.touch])
                    self.model.setTrackpad(true)
                    // The one place iOS's own keyboard taps back: the keys going blank is easy to miss.
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            }
        default:
            break
        }
    }

    /// The finger lifts (at `point`), or another came down (no point): the key acts.
    private func finish(_ press: Press, at point: CGPoint?) {
        press.timer?.invalidate()
        press.callout?.removeFromSuperview()
        switch press.key.kind {
        case .character(let character):
            if let alternates = press.alternates {
                alternates.removeFromSuperview()
                if let chosen = alternates.chosen {
                    model.typeCharacter(chosen == 0 ? character : press.key.alternates[chosen - 1])
                }
            } else {
                shadow(press, typed: character)
                model.typeCharacter(character)
            }
            for held in presses.values where held.key.kind == .shift { held.typedWith = true }
        case .shift:
            // Slid from shift onto a letter: a capital, and shift is done.
            if let point, let key = key(at: point), let character = key.character {
                model.typeCharacter(character)
                model.shiftReleasedAfterTyping()
            } else if press.typedWith {
                model.shiftReleasedAfterTyping()
            }
        case .space:
            if press.trackpadX != nil { model.setTrackpad(false) } else { model.space() }
        case .ret: model.newline()
        case .more, .symbols:
            // Slid onto a key of the page: it's typed, and the page goes back.
            if let point, let key = key(at: point), let character = key.character {
                model.typeCharacter(character)
                if let pages = press.pages, model.layout == pages.to { model.show(pages.from) }
            }
        case .language: model.switchLanguage()
        case .globe: model.nextKeyboard()
        case .backspace: break
        }
    }

    /// How near a tap must come down to another letter's key for the word to have a say.
    static let ambiguous: CGFloat = 9

    /// The shadow of a decoder that lets the word decide a tap near the edge between two letters:
    /// what it would have typed is logged, nothing more (see KeyboardModel.shadow).
    private func shadow(_ press: Press, typed: String) {
        let point = press.start
        func distance(_ key: KeySpec) -> CGFloat {
            let dx = max(key.frame.minX - point.x, point.x - key.frame.maxX, 0)
            let dy = max(key.frame.minY - point.y, point.y - key.frame.maxY, 0)
            return hypot(dx, dy)
        }
        let nearest = keys.filter { $0.character != nil && $0 != press.key && $0.character!.first!.isLetter }
            .min { distance($0) < distance($1) }
        guard let nearest, let other = nearest.character, typed.first?.isLetter == true else { return }
        let gap = distance(nearest)
        guard gap <= Self.ambiguous else { return }
        model.shadow(typed: typed, other: other, gap: gap, touch: press.touch,
                     held: Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000), travel: press.travel)
    }

    private func showCallout(for key: KeySpec, labels: [String], selected: Int? = nil) -> Callout? {
        guard let callouts, !model.trackpad else { return nil }
        let callout = Callout(key: convert(key.frame, to: callouts), labels: labels, selected: selected,
                              within: callouts.bounds, traits: callouts.traitCollection)
        callouts.addSubview(callout)
        return callout
    }
}

// MARK: - Looks

private enum Palette {
    static let letter = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white }
    static let special = UIColor {
        $0.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.675, green: 0.694, blue: 0.725, alpha: 1)
    }
    static let shadow = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.6) : UIColor(white: 0, alpha: 0.3) }
}

/// One key as drawn: a rounded face with a hairline shadow under it, and its letter or symbol.
private final class KeyView: UIView {
    let spec: KeySpec
    private let label = UILabel()
    private let image = UIImageView()

    init(spec: KeySpec) {
        self.spec = spec
        super.init(frame: spec.frame)
        isUserInteractionEnabled = false
        layer.cornerRadius = 8.5
        layer.cornerCurve = .continuous
        layer.shadowOffset = CGSize(width: 0, height: 1)
        layer.shadowRadius = 0
        layer.shadowOpacity = 1
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        image.contentMode = .center
        for part in [label, image] as [UIView] {
            part.frame = bounds.insetBy(dx: 2, dy: 0)
            part.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(part)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(model: KeyboardModel, pressed: Bool) {
        var text: String?
        var symbol: String?
        var special = true
        var prominent = false
        var dimmed = false
        switch spec.kind {
        case .character(let character):
            text = model.display(character)
            special = false
        case .shift:
            symbol = model.shift == .locked ? "capslock.fill" : (model.shift == .once ? "shift.fill" : "shift")
            special = model.shift == .off
        case .backspace: symbol = "delete.left"
        case .more: text = model.layout.isLetters ? "123" : (model.letters == .russian ? "АБВ" : "ABC")
        case .symbols: text = model.layout == .digits ? "#+=" : "123"
        case .language: text = model.letters == .russian ? "RU" : "EN"
        case .globe: symbol = "globe"
        case .space:
            text = model.letters == .russian ? "пробел" : "space"
            special = false
        case .ret:
            let key = model.returnKey
            if let title = key.title { text = title } else { symbol = "return" }
            prominent = key.prominent && key.enabled
            dimmed = !key.enabled
        }
        if model.trackpad {   // as iOS does: the keys go blank under a moving cursor
            text = nil
            symbol = nil
        }
        let single = text?.count == 1
        label.font = single ? .systemFont(ofSize: 25, weight: .light) : .systemFont(ofSize: 16)
        label.text = text
        label.textColor = prominent ? .white : (dimmed ? .tertiaryLabel : .label)
        image.image = symbol.map {
            UIImage(systemName: $0, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .light))
        } ?? nil
        image.tintColor = prominent ? .white : .label
        // A key pressed swaps to the other shade, as iOS's do.
        let face = prominent ? UIColor.systemBlue : (special != pressed ? Palette.special : Palette.letter)
        backgroundColor = face.resolvedColor(with: traitCollection)
        layer.shadowColor = Palette.shadow.resolvedColor(with: traitCollection).cgColor
        // A character key pressed shows its callout instead.
        if pressed, spec.character != nil { backgroundColor = Palette.letter.resolvedColor(with: traitCollection) }
    }
}

/// The bubble over a pressed key with its letter big — or, for a held key, its alternates to slide
/// along. The key itself is the bubble's stem.
private final class Callout: UIView {
    private let labels: [String]
    private var cells: [UILabel] = []
    private(set) var chosen: Int?
    private let cellWidth: CGFloat
    private let head: CGRect

    init(key: CGRect, labels: [String], selected: Int?, within bounds: CGRect, traits: UITraitCollection) {
        self.labels = labels
        cellWidth = max(key.width + (labels.count == 1 ? 16 : 6), 34)
        let headHeight: CGFloat = 54
        let width = cellWidth * CGFloat(labels.count) + (labels.count == 1 ? 0 : 8)
        var x = labels.count == 1 ? key.midX - width / 2 : key.minX - 4
        if x + width > bounds.maxX - 2 { x = (labels.count == 1 ? bounds.maxX - 2 : key.maxX + 4) - width }
        x = max(x, bounds.minX + 2)
        let headTop = max(key.minY - headHeight + 4, bounds.minY)
        let frame = CGRect(x: x, y: headTop, width: width, height: key.maxY - headTop).union(key)
        head = CGRect(x: x - frame.minX, y: headTop - frame.minY, width: width, height: min(headHeight, key.minY + 10 - headTop))
        chosen = selected ?? 0
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)

        let stem = CGRect(origin: CGPoint(x: key.minX - frame.minX, y: key.minY - frame.minY), size: key.size)
        let face = Palette.letter.resolvedColor(with: traits).cgColor
        let neckTop = head.maxY - 10
        let neck = UIBezierPath()
        neck.move(to: CGPoint(x: max(head.minX, stem.minX - 8), y: neckTop))
        neck.addLine(to: CGPoint(x: min(head.maxX, stem.maxX + 8), y: neckTop))
        neck.addLine(to: CGPoint(x: stem.maxX, y: stem.minY + 12))
        neck.addLine(to: CGPoint(x: stem.minX, y: stem.minY + 12))
        neck.close()
        for path in [UIBezierPath(roundedRect: head, cornerRadius: 10), UIBezierPath(roundedRect: stem, cornerRadius: 8.5), neck] {
            let shape = CAShapeLayer()
            shape.path = path.cgPath
            shape.fillColor = face
            layer.addSublayer(shape)
        }
        for (index, text) in labels.enumerated() {
            let cell = UILabel(frame: CGRect(x: head.minX + (labels.count == 1 ? 0 : 4) + CGFloat(index) * cellWidth,
                                             y: head.minY + 4, width: cellWidth, height: head.height - 12))
            cell.text = text
            cell.textAlignment = .center
            cell.font = .systemFont(ofSize: labels.count == 1 ? 34 : 26, weight: .light)
            cell.layer.cornerRadius = 7
            cell.layer.masksToBounds = true
            addSubview(cell)
            cells.append(cell)
        }
        highlight()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sliding along the alternates: the one under the finger; off the bubble, none.
    func select(at point: CGPoint) {
        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard local.y > head.minY - 40, local.y < bounds.maxY + 50 else {
            chosen = nil
            highlight()
            return
        }
        let index = Int(((local.x - head.minX - 4) / cellWidth).rounded(.down))
        chosen = min(max(index, 0), labels.count - 1)
        highlight()
    }

    private func highlight() {
        guard labels.count > 1 else { return }
        for (index, cell) in cells.enumerated() {
            let on = index == chosen
            cell.backgroundColor = on ? .systemBlue : .clear
            cell.textColor = on ? .white : .label.resolvedColor(with: traitCollection)
        }
    }
}
