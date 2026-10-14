import UIKit

/// Above the keys: the suggestions for the word being typed, as on iOS's own keyboard; otherwise
/// what was last dictated (a tap types it again) or how the keyboard is doing.
final class KeyboardStrip: UIView {
    static let height: CGFloat = 40

    weak var model: KeyboardModel?

    private let suggestions = UIStackView()
    private let note = UILabel()
    private let insert = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        suggestions.axis = .horizontal
        suggestions.distribution = .fillEqually
        note.font = .preferredFont(forTextStyle: .footnote)
        note.lineBreakMode = .byTruncatingHead
        insert.setImage(UIImage(systemName: "text.insert"), for: .normal)
        insert.tintColor = .secondaryLabel
        insert.addAction(UIAction { [weak self] _ in self?.model?.typeLast() }, for: .touchUpInside)
        for part in [suggestions, note, insert] as [UIView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        NSLayoutConstraint.activate([
            suggestions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            suggestions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            suggestions.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            suggestions.bottomAnchor.constraint(equalTo: bottomAnchor),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
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
        let words = model.suggestions
        suggestions.isHidden = words.isEmpty
        note.isHidden = !words.isEmpty
        insert.isHidden = !words.isEmpty || model.last == nil
        note.text = model.last ?? model.status
        note.textColor = model.last == nil ? .secondaryLabel : .label

        let shown = suggestions.arrangedSubviews.compactMap { ($0 as? SuggestionView)?.word }
        guard shown != words else { return }
        suggestions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, word) in words.enumerated() {
            suggestions.addArrangedSubview(SuggestionView(word: word, divided: index > 0) { [weak model] in
                UIDevice.current.playInputClick()
                model?.choose(suggestion: word)
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
