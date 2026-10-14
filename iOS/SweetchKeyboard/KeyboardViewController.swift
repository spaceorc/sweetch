import SwiftUI
import UIKit

/// sweetch's keyboard: it can't listen (iOS gives keyboards no microphone), so the Action Button
/// does, and the keyboard types what the Mac heard into the field as soon as it's heard. It also
/// tells the Mac what the field holds, for the prefix. A few keys for small fixes; the globe goes
/// back to the usual keyboard.
final class KeyboardViewController: UIInputViewController {
    private lazy var model = KeyboardModel(controller: self)

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: KeyboardView(model: model, showsGlobe: needsInputModeSwitchKey))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.heightAnchor.constraint(equalToConstant: 220),
        ])
        host.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.appeared()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.disappeared()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.fieldChanged()
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var status = "connecting…"
    @Published private(set) var last: String?

    private weak var controller: UIInputViewController?
    private var listening: Task<Void, Never>?
    private var fieldNote: Task<Void, Never>?
    private var server: Server?
    private let lastSeqKey = "lastSeq"

    init(controller: UIInputViewController) {
        self.controller = controller
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    func appeared() {
        listening?.cancel()
        listening = Task { await listen() }
        fieldChanged()
    }

    func disappeared() {
        listening?.cancel()
        listening = nil
    }

    /// Waits on the Mac for what it hears next, and types it. What was heard before the keyboard
    /// came up isn't typed — it may have been meant for another field — but stays a tap away.
    private func listen() async {
        var seq = UserDefaults.standard.integer(forKey: lastSeqKey)
        var caughtUp = false
        while !Task.isCancelled {
            guard let mac = await reach() else {
                status = "Mac out of reach — Full Access on?"
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            do {
                let (next, text) = try await mac.next(after: seq, wait: caughtUp ? 25 : 0)
                if Task.isCancelled { return }
                if next > seq, let text, !text.isEmpty {
                    if caughtUp { type(text) } else { last = text }
                }
                seq = next
                UserDefaults.standard.set(seq, forKey: lastSeqKey)
                caughtUp = true
                status = "ready — press the Action Button"
            } catch {
                if Task.isCancelled { return }
                server = nil
                status = "Mac: \(error.localizedDescription)"
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func reach() async -> Server? {
        if let server { return server }
        server = await Server.reachable()
        return server
    }

    /// With a space before it when the field's text runs right up to the cursor.
    private func type(_ text: String) {
        last = text
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
        proxy?.insertText(spaced)
        fieldChanged()   // the keyboard's own typing raises no textDidChange
    }

    func typeLast() {
        if let last { type(last) }
    }

    /// Tells the Mac what the field holds before the cursor — after the user pauses.
    func fieldChanged() {
        fieldNote?.cancel()
        fieldNote = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let mac = await reach() else { return }
            await mac.noteField(proxy?.documentContextBeforeInput ?? "")
        }
    }

    func space() { proxy?.insertText(" "); fieldChanged() }
    func newline() { proxy?.insertText("\n"); fieldChanged() }
    func backspace() { proxy?.deleteBackward(); fieldChanged() }
    func nextKeyboard() { controller?.advanceToNextInputMode() }
}

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool

    var body: some View {
        VStack(spacing: 8) {
            Text(model.last ?? model.status)
                .font(.callout)
                .foregroundStyle(model.last == nil ? .secondary : .primary)
                .lineLimit(3)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            if model.last != nil {
                Text(model.status).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if showsGlobe { key(systemImage: "globe", action: model.nextKeyboard) }
                key(systemImage: "text.insert", action: model.typeLast)
                key(title: "space", action: model.space).frame(maxWidth: .infinity)
                key(systemImage: "delete.left", action: model.backspace)
                key(systemImage: "return", action: model.newline)
            }
        }
        .padding(8)
    }

    private func key(title: String? = nil, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let systemImage { Image(systemName: systemImage) } else { Text(title ?? "") }
            }
            .frame(minWidth: 44, maxWidth: title == nil ? 52 : .infinity, minHeight: 44)
            .background(Color(uiColor: .systemBackground).opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
