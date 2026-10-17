import UIKit

/// Above the keys: the profile in use — personal, work, agent, a tap picks another — then the
/// suggestions for the word being typed, as on iOS's own keyboard; otherwise what was last
/// dictated (a tap types it again) or how the keyboard is doing.
final class KeyboardStrip: UIView {
    static let height: CGFloat = 40

    weak var model: KeyboardModel?

    private let suggestions = UIStackView()
    private let note = UILabel()
    private let insert = UIButton(type: .system)
    private let profiles = UIStackView()
    private var profileButtons: [UIButton] = []
    private static let symbols = ["person", "briefcase", "sparkles"]

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
        profiles.axis = .horizontal
        profiles.spacing = 2
        for name in Profiles.Name.allCases {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: Self.symbols[name.rawValue],
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium)), for: .normal)
            button.layer.cornerRadius = 13
            button.addAction(UIAction { [weak self] _ in
                UIDevice.current.playInputClick()
                self?.model?.chooseProfile(name)
            }, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 30).isActive = true
            button.heightAnchor.constraint(equalToConstant: 26).isActive = true
            profiles.addArrangedSubview(button)
            profileButtons.append(button)
        }
        for part in [profiles, suggestions, note, insert] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        NSLayoutConstraint.activate([
            profiles.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            profiles.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            suggestions.leadingAnchor.constraint(equalTo: profiles.trailingAnchor, constant: 4),
            suggestions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            suggestions.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            suggestions.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.leadingAnchor.constraint(equalTo: profiles.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(lessThanOrEqualTo: insert.leadingAnchor, constant: -8),
            note.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            insert.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            insert.centerYAnchor.constraint(equalTo: note.centerYAnchor),
            insert.widthAnchor.constraint(equalToConstant: 36),
            insert.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func render() {
        guard let model else { return }
        // The profile in use stands out: filled when the user picked it, faint when it's a guess.
        for (index, button) in profileButtons.enumerated() {
            let on = index == model.profile.rawValue
            button.tintColor = on ? .label : .tertiaryLabel
            button.backgroundColor = on ? UIColor.label.withAlphaComponent(model.profileManual ? 0.18 : 0.08) : .clear
        }
        // Just after a correction: first, the word as typed, to take it back.
        let undo = model.revertOffer
        let words = (undo.map { ["↶ " + $0] } ?? []) + model.suggestions.prefix(undo == nil ? 3 : 2)
        suggestions.isHidden = words.isEmpty
        note.isHidden = !words.isEmpty
        insert.isHidden = !words.isEmpty || model.last == nil
        note.text = model.last ?? model.status
        note.textColor = model.last == nil ? .secondaryLabel : .label

        let shown = suggestions.arrangedSubviews.compactMap { ($0 as? SuggestionView)?.word }
        guard shown != words else { return }
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, word) in words.enumerated() {
            let isUndo = index == 0 && undo != nil
            suggestions.addArrangedSubview(SuggestionView(word: word, divided: index > 0) { [weak model] in
                UIDevice.current.playInputClick()
                if isUndo { model?.revertAutoFix() } else { model?.choose(suggestion: word) }
            })
        }
    }
}

/// One suggestion: the word, and a hairline between it and the one before.
private final class SuggestionView: UIView {
    let word: String

    init(word: String, divided: Bool, chosen: @escaping () -> Void) {
        self.word = word
        super.init(frame: .zero)
        let button = UIButton(type: .system)
        button.setTitle(word, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17)
        button.titleLabel?.lineBreakMode = .byTruncatingMiddle
        button.addAction(UIAction { _ in chosen() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
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
