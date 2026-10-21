import UIKit

/// Above the keys: incognito, a tap turns it — then the
/// suggestions for the word being typed, as on iOS's own keyboard; otherwise what was last
/// dictated (a tap types it again) or how the keyboard is doing.
final class KeyboardStrip: UIView {
    static let height: CGFloat = 40

    weak var model: KeyboardModel?

    private let suggestions = UIStackView()
    private let note = UILabel()
    private let insert = UIButton(type: .system)
    private let microphone = UIButton(type: .system)
    private let incognitoButton = UIButton(type: .system)
    private var shownIncognito: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = KeyboardSurface.touchable   // see there: clear would let touches through
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        note.font = .preferredFont(forTextStyle: .footnote)
        note.lineBreakMode = .byTruncatingHead
        insert.setImage(UIImage(systemName: "text.insert"), for: .normal)
        insert.tintColor = .secondaryLabel
        insert.addAction(UIAction { [weak self] _ in self?.model?.typeLast() }, for: .touchUpInside)
        incognitoButton.setImage(UIImage(systemName: "eye.slash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)), for: .normal)
        incognitoButton.layer.cornerRadius = 13
        incognitoButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        incognitoButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        incognitoButton.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.model?.toggleIncognito()
        }, for: .touchUpInside)
        microphone.setImage(UIImage(systemName: "mic.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)), for: .normal)
        microphone.tintColor = .label
        microphone.addAction(UIAction { [weak self] _ in
            UIDevice.current.playInputClick()
            self?.model?.openDictation()
        }, for: .touchUpInside)
        for part in [incognitoButton, suggestions, note, insert, microphone] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        NSLayoutConstraint.activate([
            // Incognito first: nothing to pick here about how the user writes — that's the keyboard's to learn.
            incognitoButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            incognitoButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            suggestions.leadingAnchor.constraint(equalTo: incognitoButton.trailingAnchor, constant: 4),
            microphone.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            microphone.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            microphone.widthAnchor.constraint(equalToConstant: 36),
            microphone.heightAnchor.constraint(equalToConstant: 32),
            suggestions.trailingAnchor.constraint(equalTo: microphone.leadingAnchor, constant: -2),
            suggestions.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            suggestions.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.leadingAnchor.constraint(equalTo: incognitoButton.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(lessThanOrEqualTo: insert.leadingAnchor, constant: -8),
            note.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            insert.trailingAnchor.constraint(equalTo: microphone.leadingAnchor, constant: -4),
            insert.centerYAnchor.constraint(equalTo: note.centerYAnchor),
            insert.widthAnchor.constraint(equalToConstant: 36),
            insert.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func render() {
        guard let model else { return }
        showIncognito(model.incognito)
        // Just after a correction: first, the word as typed, to take it back.
        // Then the decoder's runners-up for it (green), and the suggestions in what room is left.
        let undo = model.revertOffer
        let forward = Array(model.alternativesOffer.prefix(undo == nil ? 3 : 2))
        let lead = (undo.map { [$0] } ?? []) + forward
        let words = lead + model.suggestions.filter { !forward.contains($0) }.prefix(3 - lead.count)
        func kind(_ index: Int) -> SuggestionView.Kind {
            undo != nil && index == 0 ? .undo : index < lead.count ? .forward : .word
        }
        suggestions.isHidden = words.isEmpty
        note.isHidden = !words.isEmpty
        insert.isHidden = !words.isEmpty || model.last == nil
        note.text = model.incognito ? model.status : model.last ?? model.status
        note.textColor = model.last == nil ? .secondaryLabel : .label

        let shown = suggestions.arrangedSubviews.compactMap { ($0 as? SuggestionView).map { "\($0.kind)" + $0.word } }
        guard shown != words.enumerated().map({ "\(kind($0.offset))" + $0.element }) else { return }
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, word) in words.enumerated() {
            let k = kind(index)
            suggestions.addArrangedSubview(SuggestionView(word: word, divided: index > 0 && kind(index) == .word && kind(index - 1) == .word,
                                                          kind: k, model: model) { [weak model] picked in
                UIDevice.current.playInputClick()
                switch k {
                case .undo: model?.revertAutoFix()
                case .forward: model?.chooseAlternative(picked)
                case .word: model?.choose(suggestion: picked)
                }
            })
        }
    }

    /// Incognito at a glance, and one tap to turn it: dark when on — by hand, or in a private tab
    /// — faint when off.
    private func showIncognito(_ on: Bool) {
        guard shownIncognito != on else { return }
        shownIncognito = on
        incognitoButton.tintColor = on ? .systemBackground : .tertiaryLabel
        incognitoButton.backgroundColor = on ? UIColor.label.withAlphaComponent(0.85) : .clear
        incognitoButton.accessibilityLabel = on ? "Incognito on" : "Incognito off"
    }
}

/// One suggestion: the word, and a hairline between it and the one before. `undo`: the word as
/// typed, to take a correction back — a red capsule, a button that looks like one, not another
/// word. `forward`: a word the decoder nearly put in instead of the one just ended — a green one.
private final class SuggestionView: UIView {
    enum Kind { case word, undo, forward }
    let word: String
    let kind: Kind
    var undo: Bool { kind == .undo }

    /// `chosen`: what was tapped — the word, or one of the emoji of an emoji group.
    init(word: String, divided: Bool, kind: Kind = .word, model: KeyboardModel? = nil, chosen: @escaping (String) -> Void) {
        self.word = word
        self.kind = kind
        super.init(frame: .zero)
        let button: UIView
        if Emoji.isEmoji(word) {
            // Several emoji in one place, each its own button.
            let group = UIStackView()
            group.axis = .horizontal
            group.distribution = .fillEqually
            for emoji in word.split(separator: " ").map(String.init) {
                let one = UIButton(type: .system)
                one.setTitle(emoji, for: .normal)
                one.titleLabel?.font = .systemFont(ofSize: 22)
                one.addAction(UIAction { _ in chosen(emoji) }, for: .touchUpInside)
                // A long press: the skin tones, and «not again».
                one.menu = Self.emojiMenu(emoji, model: model)
                group.addArrangedSubview(one)
            }
            button = group
        } else if undo || kind == .forward {
            var look = UIButton.Configuration.filled()
            look.cornerStyle = .capsule
            look.baseBackgroundColor = undo ? .label : .clear
            look.baseForegroundColor = undo ? .systemBackground : .label
            look.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10)
            look.attributedTitle = AttributedString(word, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .medium)]))
            look.titleLineBreakMode = .byTruncatingMiddle
            let capsule = undo ? UIButton(configuration: look) : DashedCapsule(configuration: look)
            capsule.accessibilityLabel = undo ? "Undo correction, keep \(word)" : "Replace with \(word)"
            capsule.addAction(UIAction { _ in chosen(word) }, for: .touchUpInside)
            button = capsule
        } else {
            let plain = UIButton(type: .system)
            plain.setTitle(word, for: .normal)
            plain.setTitleColor(.label, for: .normal)
            plain.titleLabel?.font = .systemFont(ofSize: 17)
            plain.titleLabel?.lineBreakMode = .byTruncatingMiddle
            plain.addAction(UIAction { _ in chosen(word) }, for: .touchUpInside)
            button = plain
        }
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        if kind != .word {
            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: centerXAnchor),
                button.centerYAnchor.constraint(equalTo: centerYAnchor),
                button.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
                button.heightAnchor.constraint(equalToConstant: 32),
            ])
        } else {
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                button.topAnchor.constraint(equalTo: topAnchor),
                button.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        if divided {
            let line = UIView()
            line.backgroundColor = .separator
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.widthAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
                line.centerYAnchor.constraint(equalTo: centerYAnchor),
                line.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static func emojiMenu(_ emoji: String, model: KeyboardModel?) -> UIMenu {
        var items: [UIMenuElement] = []
        if let variants = Emoji.toneVariants(emoji) {
            items.append(UIMenu(options: .displayInline, children: variants.map { variant in
                UIAction(title: variant, state: variant == emoji ? .on : .off) { [weak model] _ in
                    UIDevice.current.playInputClick()
                    model?.chooseEmoji(variant)
                }
            }))
        }
        var hide: [UIAction] = []
        if let word = model?.emojiWord {
            hide.append(UIAction(title: "Не показывать для «\(word)»", image: UIImage(systemName: "eye.slash")) { [weak model] _ in
                model?.hideEmoji(emoji, forThisWord: true)
            })
        }
        hide.append(UIAction(title: "Не показывать никогда", image: UIImage(systemName: "nosign"), attributes: .destructive) { [weak model] _ in
            model?.hideEmoji(emoji, forThisWord: false)
        })
        items.append(UIMenu(options: .displayInline, children: hide))
        return UIMenu(title: emoji, children: items)
    }
}

/// A capsule drawn with a dashed outline: a word that could go in, not one that's there.
private final class DashedCapsule: UIButton {
    private let outline = CAShapeLayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        if outline.superlayer == nil { layer.addSublayer(outline) }
        outline.frame = bounds
        outline.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerRadius: bounds.height / 2).cgPath
        outline.fillColor = nil
        outline.strokeColor = UIColor.label.withAlphaComponent(0.55).resolvedColor(with: traitCollection).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [4, 3]
    }
}
