import SwiftUI
import UIKit

/// sweetch's keyboard: Russian, English, digits and symbols, and a big microphone key. A keyboard
/// can't listen (iOS gives keyboards no microphone), so the key asks the app to: at once when the
/// app's microphone is warm from the last dictation, by opening the app when it isn't. What the Mac
/// heard is typed as soon as it's heard — the Action Button's dictations too — and the layout
/// follows the language of it. The Mac is told what the field holds, for the prefix.
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
            host.view.heightAnchor.constraint(equalToConstant: 268),
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

    /// The app's microphone, as last heard from it.
    enum Microphone { case unknown, cold, warm, listening }

    @Published var layout: Layout = .russian
    @Published private(set) var shift: Shift = .once
    @Published private(set) var microphone: Microphone = .unknown
    @Published private(set) var status = "connecting…"
    @Published private(set) var last: String?

    private weak var controller: UIInputViewController?
    private var letters: Layout = .russian
    private var listening: Task<Void, Never>?
    private var fieldNote: Task<Void, Never>?
    private var server: Server?
    private var lastSpaceAt = Date.distantPast
    private let lastSeqKey = "lastSeq"
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    init(controller: UIInputViewController) {
        self.controller = controller
        Signal.warm.observe { [weak self] in self?.microphone = .warm }
        Signal.listening.observe { [weak self] in self?.microphone = .listening }
        Signal.cold.observe { [weak self] in self?.microphone = .cold }
    }

    private var proxy: UITextDocumentProxy? { controller?.textDocumentProxy }

    /// The app the keyboard is typing into. iOS doesn't say. Before iOS 16 a private key did; since,
    /// the host's process id leads to its connection with the keyboard, and that to its bundle id.
    private(set) lazy var host: String? = {
        guard let controller else { return nil }
        for holder in [controller, controller.parent].compactMap({ $0 as NSObject? })
        where holder.responds(to: NSSelectorFromString("_hostBundleID")) {
            if let id = holder.value(forKey: "_hostBundleID") as? String, !id.isEmpty, id != "<null>" {
                hostTrail.append("_hostBundleID")
                return id
            }
        }
        return hostByProcess()
    }()

    /// How the host was looked for, step by step: sent to the Mac's log.
    private var hostTrail: [String] = []

    private func hostByProcess() -> String? {
        let parent = controller?.parent as NSObject?
        guard let parent, parent.responds(to: NSSelectorFromString("_hostPID")),
              let pid = parent.value(forKey: "_hostPID") else { hostTrail.append("no _hostPID"); return nil }
        hostTrail.append("pid \(pid)")
        guard let service = NSClassFromString("PKService") as AnyObject as? NSObjectProtocol,
              service.responds(to: NSSelectorFromString("defaultService")),
              let shared = service.perform(NSSelectorFromString("defaultService"))?.takeUnretainedValue() as? NSObjectProtocol
        else { hostTrail.append("no PKService"); return nil }
        guard shared.responds(to: NSSelectorFromString("personalities")),
              let personalities = shared.perform(NSSelectorFromString("personalities"))?.takeUnretainedValue() as? [String: Any],
              let infos = personalities.first?.value as? [AnyHashable: Any]
        else { hostTrail.append("no personalities"); return nil }
        hostTrail.append("\(personalities.count) personalities, \(infos.count) infos")
        guard let info = infos.first(where: { "\($0.key)".contains("\(pid)") })?.value as? NSObjectProtocol,
              info.responds(to: NSSelectorFromString("connection")),
              let connection = info.perform(NSSelectorFromString("connection"))?.takeUnretainedValue() as? NSObjectProtocol,
              connection.responds(to: NSSelectorFromString("_xpcConnection")),
              let xpc = connection.perform(NSSelectorFromString("_xpcConnection"))?.takeUnretainedValue()
        else { hostTrail.append("no connection for the pid among \(infos.keys.map { "\($0)" })"); return nil }
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "xpc_connection_copy_bundle_id") else {
            hostTrail.append("no xpc_connection_copy_bundle_id")
            return nil
        }
        typealias CopyBundleID = @convention(c) (AnyObject) -> UnsafeMutablePointer<CChar>?
        guard let id = unsafeBitCast(symbol, to: CopyBundleID.self)(xpc) else { hostTrail.append("no bundle id"); return nil }
        defer { free(id) }
        hostTrail.append("xpc")
        return String(cString: id)
    }

    func appeared() {
        let found = host
        Task { [hostTrail] in
            await reach()?.log("keyboard host: \(found ?? "unknown") — \(hostTrail.joined(separator: "; "))")
        }
        listening?.cancel()
        listening = Task { await listen() }
        Signal.ping.post()
        fieldChanged()
        autoCapitalise()
    }

    func disappeared() {
        listening?.cancel()
        listening = nil
    }

    // MARK: Typing

    func tap(_ key: String) {
        haptic.impactOccurred()
        let text = shift == .off || !layout.isLetters ? key : key.uppercased()
        proxy?.insertText(text)
        if shift == .once { shift = .off }
        if !layout.isLetters, key == "'" || key == "." || key == "," || key == "?" || key == "!" {
            layout = letters   // as iOS does: after punctuation, back to the letters
        }
        fieldChanged()
    }

    /// A double space ends the sentence, as on iOS's own keyboard.
    func space() {
        haptic.impactOccurred()
        let before = proxy?.documentContextBeforeInput ?? ""
        if Date().timeIntervalSince(lastSpaceAt) < 0.4, before.hasSuffix(" "), let previous = before.dropLast().last,
           previous.isLetter || previous.isNumber {
            proxy?.deleteBackward()
            proxy?.insertText(". ")
            lastSpaceAt = .distantPast
        } else {
            proxy?.insertText(" ")
            lastSpaceAt = Date()
        }
        if !layout.isLetters { layout = letters }
        autoCapitalise()
        fieldChanged()
    }

    func newline() {
        haptic.impactOccurred()
        proxy?.insertText("\n")
        autoCapitalise()
        fieldChanged()
    }

    func backspace() {
        proxy?.deleteBackward()
        autoCapitalise()
        fieldChanged()
    }

    func shiftTapped() {
        haptic.impactOccurred()
        switch shift {
        case .off: shift = .once
        case .once: shift = .locked
        case .locked: shift = .off
        }
    }

    func switchLanguage() {
        haptic.impactOccurred()
        letters = letters == .russian ? .english : .russian
        layout = letters
    }

    func switchDigits() {
        haptic.impactOccurred()
        layout = layout.isLetters ? .digits : letters
    }

    func switchSymbols() {
        layout = layout == .digits ? .symbols : .digits
    }

    func nextKeyboard() { controller?.advanceToNextInputMode() }

    /// A capital at the start of the field and of a sentence, where the field wants one.
    private func autoCapitalise() {
        guard shift != .locked else { return }
        guard proxy?.autocapitalizationType != UITextAutocapitalizationType.none else {
            shift = .off
            return
        }
        let before = (proxy?.documentContextBeforeInput ?? "")
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let sentenceStart = trimmed.isEmpty || (before.last?.isWhitespace == true && ".!?\n".contains(trimmed.last!))
            || before.hasSuffix("\n")
        shift = sentenceStart ? .once : .off
    }

    // MARK: Dictation

    /// The app listens: at once when its microphone is warm; otherwise the app is opened to turn it on.
    func microphoneTapped() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch microphone {
        case .warm, .listening:
            microphone = microphone == .warm ? .listening : .warm
            Signal.toggle.post()
        case .cold, .unknown:
            Task {
                Signal.ping.post()
                try? await Task.sleep(for: .milliseconds(250))
                if microphone == .warm {
                    microphone = .listening
                    Signal.toggle.post()
                } else {
                    openApp()
                }
            }
        }
    }

    /// A keyboard has no UIApplication to open URLs with; the responder chain reaches the host's
    /// scene and application. A scene takes its own options object, an application a dictionary.
    private func openApp() {
        var link = URLComponents(string: "sweetch://dictate")!
        if let host { link.queryItems = [URLQueryItem(name: "back", value: host)] }
        guard let url = link.url else { return }
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
        status = "open sweetch to turn the microphone on"
    }

    /// Waits on the Mac for what it hears next, and types it. What was heard before the keyboard
    /// came up isn't typed — it may have been meant for another field — but stays a tap away.
    private func listen() async {
        var seq = UserDefaults.standard.integer(forKey: lastSeqKey)
        var caughtUp = false
        while !Task.isCancelled {
            guard let mac = await reach() else {
                status = "Mac out of reach"
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
                status = "ready" + (host.map { " · \(HostApp.name($0))" } ?? " · app unknown")
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

    /// With a space before it when the field's text runs right up to the cursor; the layout then
    /// follows the language of what was said.
    private func type(_ text: String) {
        last = text
        let before = proxy?.documentContextBeforeInput ?? ""
        let spaced = before.isEmpty || before.last?.isWhitespace == true ? text : " " + text
        proxy?.insertText(spaced)
        let latin = text.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }.count
        let cyrillic = text.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        if latin + cyrillic > 0 {
            letters = latin > cyrillic ? .english : .russian
            layout = letters
        }
        autoCapitalise()
        fieldChanged()
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
            await mac.noteField(proxy?.documentContextBeforeInput ?? "", app: host.map(HostApp.name))
        }
    }
}

// MARK: - Views

struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    let showsGlobe: Bool

    private let spacing: CGFloat = 6
    private let keyHeight: CGFloat = 46

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 6
            let unit = (width - spacing * 10) / 11   // eleven keys fit the widest row
            let letter = model.layout.rows[0].count == 10 ? (width - spacing * 9) / 10 : unit
            VStack(spacing: 9) {
                strip
                ForEach(Array(model.layout.rows.enumerated()), id: \.offset) { index, row in
                    // The third row's shift and backspace take what the letters leave.
                    let side = (width - CGFloat(row.count) * letter - CGFloat(row.count + 1) * spacing) / 2
                    HStack(spacing: spacing) {
                        if index == 2 { leftOfThirdRow(width: max(side, 0)) }
                        ForEach(Array(row), id: \.self) { character in
                            let key = String(character)
                            Key(label: label(key), width: letter, height: keyHeight) { model.tap(key) }
                        }
                        if index == 2 { Repeating(width: max(side, 0), height: keyHeight, action: model.backspace) }
                    }
                    .frame(width: width)
                }
                bottomRow(unit: unit)
                    .frame(width: width)
            }
            .padding(.horizontal, 3)
            .padding(.top, 6)
        }
    }

    private func label(_ key: String) -> String {
        model.layout.isLetters && model.shift != .off ? key.uppercased() : key
    }

    /// What the keyboard last typed, or how it's doing.
    private var strip: some View {
        HStack {
            Text(model.last ?? model.status)
                .font(.footnote)
                .foregroundStyle(model.last == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            if model.last != nil {
                Button { model.typeLast() } label: { Image(systemName: "text.insert") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    @ViewBuilder
    private func leftOfThirdRow(width: CGFloat) -> some View {
        if model.layout.isLetters {
            Key(systemImage: model.shift == .locked ? "capslock.fill" : (model.shift == .once ? "shift.fill" : "shift"),
                width: width, height: keyHeight, dark: true, action: model.shiftTapped)
        } else {
            Key(label: model.layout == .digits ? "#+=" : "123", width: width, height: keyHeight, dark: true,
                action: model.switchSymbols)
        }
    }

    private func bottomRow(unit: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Key(label: model.layout.isLetters ? "123" : (model.layout == .digits || model.layout == .symbols ? "АБВ" : "123"),
                width: unit * 1.4, height: keyHeight, dark: true, action: model.switchDigits)
            if showsGlobe {
                Key(systemImage: "globe", width: unit * 1.1, height: keyHeight, dark: true, action: model.nextKeyboard)
            }
            Key(label: model.layout == .english ? "EN" : "RU", width: unit * 1.1, height: keyHeight, dark: true,
                action: model.switchLanguage)
            Key(label: model.layout == .english ? "space" : "пробел", width: nil, height: keyHeight, action: model.space)
            MicrophoneKey(state: model.microphone, width: unit * 2.4, height: keyHeight, action: model.microphoneTapped)
            Key(systemImage: "return", width: unit * 1.6, height: keyHeight, dark: true, action: model.newline)
        }
    }
}

/// A key that acts as the finger lifts — on touch-down a SwiftUI button waits to tell a tap from a
/// scroll, which typing can't afford.
struct Key: View {
    var label: String? = nil
    var systemImage: String? = nil
    let width: CGFloat?
    let height: CGFloat
    var dark = false
    var fill: Color? = nil
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        Group {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 18)) }
            else { Text(label ?? "").font(.system(size: (label?.count ?? 0) > 1 ? 15 : 22)) }
        }
        .frame(maxWidth: width == nil ? .infinity : nil)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(pressed ? Color(uiColor: .systemGray3) : fill ?? (dark ? Color(uiColor: .systemGray4) : Color(uiColor: .systemBackground)))
            .shadow(color: .black.opacity(0.25), radius: 0, y: 1))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in
                pressed = false
                action()
            })
    }
}

/// Backspace: once on touch, then over and over while held.
struct Repeating: View {
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    @State private var timer: Timer?

    var body: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 18))
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(timer == nil ? Color(uiColor: .systemGray4) : Color(uiColor: .systemGray3))
                .shadow(color: .black.opacity(0.25), radius: 0, y: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard timer == nil else { return }
                    action()
                    var fired = 0
                    timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                        fired += 1
                        if fired > 5 { MainActor.assumeIsolated { action() } }   // held past 0.4 s
                    }
                }
                .onEnded { _ in
                    timer?.invalidate()
                    timer = nil
                })
    }
}

struct MicrophoneKey: View {
    let state: KeyboardModel.Microphone
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Key(systemImage: state == .listening ? "stop.fill" : "mic.fill", width: width, height: height,
            fill: state == .listening ? .red : (state == .warm ? .accentColor : .accentColor.opacity(0.6)), action: action)
            .foregroundStyle(.white)
    }
}
