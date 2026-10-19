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
        let undo = model.revertOffer
        let words = (undo.map { [$0] } ?? []) + model.suggestions.prefix(undo == nil ? 3 : 2)
        suggestions.isHidden = words.isEmpty
        note.isHidden = !words.isEmpty
        insert.isHidden = !words.isEmpty || model.last == nil
        note.text = model.incognito ? model.status : model.last ?? model.status
        note.textColor = model.last == nil ? .secondaryLabel : .label

        let shown = suggestions.arrangedSubviews.compactMap { ($0 as? SuggestionView).map { $0.undo ? "↶" + $0.word : $0.word } }
        guard shown != words.enumerated().map({ $0.offset == 0 && undo != nil ? "↶" + $0.element : $0.element }) else { return }
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, word) in words.enumerated() {
            let isUndo = index == 0 && undo != nil
            suggestions.addArrangedSubview(SuggestionView(word: word, divided: index > 0 && !(index == 1 && undo != nil),
                                                          undo: isUndo) { [weak model] picked in
                UIDevice.current.playInputClick()
                if isUndo { model?.revertAutoFix() } else { model?.choose(suggestion: picked) }
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
/// typed, to take a correction back — a button that looks like one, not another word.
private final class SuggestionView: UIView {
    let word: String
    let undo: Bool

    /// `chosen`: what was tapped — the word, or one of the emoji of an emoji group.
    init(word: String, divided: Bool, undo: Bool = false, chosen: @escaping (String) -> Void) {
        self.word = word
        self.undo = undo
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
                group.addArrangedSubview(one)
            }
            button = group
        } else if undo {
            var look = UIButton.Configuration.gray()
            look.cornerStyle = .capsule
            look.image = UIImage(systemName: "arrow.uturn.backward",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
            look.imagePadding = 6
            look.baseForegroundColor = .label
            look.contentInsets = NSDirectionalEdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 14)
            look.attributedTitle = AttributedString("«\(word)»", attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 16, weight: .medium)]))
            look.titleLineBreakMode = .byTruncatingMiddle
            let capsule = UIButton(configuration: look)
            capsule.layer.borderColor = UIColor.separator.cgColor
            capsule.layer.borderWidth = 1 / UIScreen.main.scale
            capsule.layer.cornerRadius = 16
            capsule.accessibilityLabel = "Undo correction, keep \(word)"
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
        if undo {
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
}
