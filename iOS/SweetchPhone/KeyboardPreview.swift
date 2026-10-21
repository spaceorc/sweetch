import SwiftUI

/// The keyboard drawn inside the app, to look at it in the simulator: launched with
/// `--keyboard-preview [russian|english|digits|symbols]`.
struct KeyboardPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.backgroundColor = .systemGroupedBackground
        let keyboard = KeyboardViewController()
        host.addChild(keyboard)
        keyboard.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(keyboard.view)
        NSLayoutConstraint.activate([
            keyboard.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            keyboard.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            keyboard.view.bottomAnchor.constraint(equalTo: host.view.safeAreaLayoutGuide.bottomAnchor),
        ])
        keyboard.didMove(toParent: host)
        let arguments = ProcessInfo.processInfo.arguments
        switch arguments.last {
        case "english": keyboard.model.switchLanguage()
        case "digits": keyboard.model.switchDigits()
        case "undo": keyboard.model.previewCorrection(typed: "Егт", fixed: "Его")
        case "alternatives": keyboard.model.previewAlternatives(typed: "сделае", fixed: "сделан", alternatives: ["сделаем", "сделает"])
        case "alternatives-left": keyboard.model.previewAlternatives(typed: "модно", fixed: nil, alternatives: ["можно", "мощно"])
        case "symbols":
            keyboard.model.switchDigits()
            keyboard.model.switchSymbols()
        default: break
        }
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
