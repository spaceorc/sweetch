import Charts
import ServiceManagement
import SwiftUI

/// What only the app itself can do, for the window: it holds the event tap, the server, the menu-bar
/// icon (AppDelegate).
struct AppActions {
    var setServer: (Bool) -> Void
    var setIncognito: (Bool) -> Void
    var forgetLastDictation: () -> Void
    var captureScreenshot: () -> Void
    var captureFullScreen: () -> Void
    var detectKey: () -> Void
    var refineDictionary: () -> Void
    var showCrashReport: () -> Void
    var reloadRemaps: () -> Void
    var privateNow: () -> String?
    var crashReport: () -> URL?
    var hotkeys: [(String, String)]
}

/// Which section the window shows — set from outside too (the menu's "All dictations").
final class MainNavigation: ObservableObject {
    @Published var section: MainView.Section? = .overview
}

/// Sweetch's own window, for the whole system — the three devices, dictation and typing, what runs
/// by itself and what it costs: the overview first, a section each from the sidebar. Fills any
/// size it's given, the whole screen too. The statistics are the iPhone's screens (Views/),
/// counted here in the background (Stats).
final class MainWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let navigation = MainNavigation()
    var onClose: (() -> Void)?

    init(actions: AppActions, section: MainView.Section = .overview) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 780),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        navigation.section = section
        window.title = "Sweetch"
        window.contentViewController = NSHostingController(rootView: MainView(actions: actions).environmentObject(navigation))
        window.setContentSize(NSSize(width: 1180, height: 780))
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("sweetch.main")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show(_ section: MainView.Section? = nil) {
        if let section { navigation.section = section }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    /// `sweetch --render-main <section> <out.png> [width height]`: the window, dark, drawn into a
    /// PNG once its numbers have loaded — for looking at a section without putting it on screen.
    static func render(_ section: String, to url: URL, size: NSSize? = nil) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let none = AppActions(setServer: { _ in }, setIncognito: { _ in }, forgetLastDictation: {}, captureScreenshot: {},
                              captureFullScreen: {}, detectKey: {}, refineDictionary: {}, showCrashReport: {},
                              reloadRemaps: {}, privateNow: { nil }, crashReport: { nil },
                              hotkeys: [("⌥Space", "Put the last words in the other layout"), ("⌘Space", "Switch the layout")])
        let main = MainWindow(actions: none, section: MainView.Section.allCases.first { $0.id == section.lowercased() } ?? .overview)
        if let size { main.window.setContentSize(size) }
        main.window.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        main.window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(20))
        guard let content = main.window.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

struct MainView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", dictations = "Dictations", words = "Words & names", typing = "Typing",
             progress = "Progress", costs = "Costs", system = "System", screenshots = "Screenshots", settings = "Settings"
        var id: String { String(describing: self) }
        var symbol: String {
            switch self {
            case .overview: "house"
            case .dictations: "mic"
            case .words: "character.book.closed"
            case .typing: "keyboard"
            case .progress: "chart.bar.xaxis"
            case .costs: "dollarsign.circle"
            case .system: "macbook.and.iphone"
            case .screenshots: "camera.viewfinder"
            case .settings: "gearshape"
            }
        }
    }

    let actions: AppActions
    @EnvironmentObject private var navigation: MainNavigation

    var body: some View {
        NavigationSplitView {
            List(selection: $navigation.section) {
                row(.overview)
                SwiftUI.Section("Dictation & typing") { row(.dictations); row(.words); row(.typing) }
                SwiftUI.Section("How it goes") { row(.progress); row(.costs) }
                SwiftUI.Section("System") { row(.system); row(.screenshots); row(.settings) }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            switch navigation.section ?? .overview {
            case .overview: OverviewPane(actions: actions)
            case .dictations: DictationsPane(actions: actions)
            case .words: WordsPane(actions: actions)
            case .typing: TypingPane(actions: actions)
            case .progress: ProgressPane()
            case .costs: CostsPane()
            case .system: SystemPane()
            case .screenshots: ScreenshotsPane(actions: actions)
            case .settings: SettingsPane(actions: actions)
            }
        }
        .tint(.mint)
    }

    private func row(_ s: Section) -> some View {
        Label(s.rawValue, systemImage: s.symbol).tag(s)
    }
}

// MARK: - Parts

private extension Color {
    static let mint = Color(red: 0.37, green: 0.83, blue: 0.71)
    static let amber = Color(red: 0.94, green: 0.69, blue: 0.38)
}

/// A section's page: its title over its content, scrolling, never wider than reads well.
private struct Page<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                        Text(title).font(.system(size: 26, weight: .bold))
                    }
                    Spacer(minLength: 12)
                    trailing()
                }
                content()
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 26)
            .frame(maxWidth: 1400, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.grouped)
    }
}

private extension Page where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

private extension View {
    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

private struct CardTitle: View {
    let title: String
    var link: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let link, let action { Button(link, action: action).buttonStyle(.link) }
        }
    }
}

private struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

private struct BigNumber: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func dollars(_ value: Any?) -> String {
    let v = (value as? NSNumber)?.doubleValue ?? 0
    return v >= 1 ? String(format: "$%.2f", v) : String(format: "$%.3f", v)
}

private func ago(_ date: Date?) -> String {
    guard let date else { return "never" }
    if Date().timeIntervalSince(date) < 60 { return "just now" }
    return date.formatted(.relative(presentation: .named))
}

private func short(_ commit: String?) -> String { commit.map { String($0.prefix(8)) } ?? "—" }

private let dayFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

// MARK: - Overview

/// The home page: the three devices, today's dictation and typing, what needs the user, the models'
/// cost — each leading to its section.
private struct OverviewPane: View {
    let actions: AppActions
    @EnvironmentObject private var navigation: MainNavigation
    @AppStorage("dictationEnabled") private var dictation = true
    @AppStorage("autoLayout") private var autoLayout = true
    @State private var incognito = Privacy.incognito
    @State private var status: SystemStatus?
    @State private var metrics: [String: Any] = [:]
    @State private var recent: [DictationsWindow.Entry] = []

    var body: some View {
        Page(title: "Overview", subtitle: Date().formatted(.dateTime.weekday(.wide).day().month(.wide))) {
            HStack(spacing: 8) {
                Toggle(isOn: $incognito) { Label("Incognito", systemImage: "eye.slash") }
                    .toggleStyle(.button)
                    .onChange(of: incognito) { _, on in actions.setIncognito(on) }
                Toggle(isOn: $dictation) { Label("Dictation", systemImage: "mic") }
                    .toggleStyle(.button)
                    .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
            }
            .controlSize(.large)
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], spacing: 12) {
                deviceCard("This MacBook", symbol: "laptopcomputer", state: macState) {
                    Fact(label: "Dictation · layouts", value: "\(dictation ? "on" : "off") · \(autoLayout ? "switched for you" : "as typed")")
                    Fact(label: "Running since", value: status?.launched?.formatted(date: .omitted, time: .shortened) ?? "—")
                    Fact(label: "Build", value: version(status?.macCommit))
                }
                deviceCard("Mac mini", symbol: "macmini", state: miniState) {
                    Fact(label: "Heard for the iPhone", value: "\(today("phone_dictations") ?? "—") today")
                    Fact(label: "Build", value: status?.mini.reachable == true ? version(status?.mini.commit) : "doesn't answer")
                    Fact(label: "Synced with this Mac", value: ago(status?.sync?.date))
                }
                deviceCard("iPhone", symbol: "iphone", state: phoneState) {
                    Fact(label: "Keyboard log came", value: ago(status?.phoneLog))
                    Fact(label: "Build", value: version(status?.phoneCommit))
                    Fact(label: "Keyboard's words built", value: status?.keyboardWords?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                dictationToday
                typingToday
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 16, alignment: .top)], spacing: 16) {
                needsYou
                models
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DictationStore.changed)) { _ in recent = DictationsPane.load(limit: 4) }
    }

    private func load() async {
        async let s = SystemStatus.gather()
        metrics = await Task.detached { Stats.currentMetrics() }.value
        recent = DictationsPane.load(limit: 4)
        var gathered = await s
        gathered.crashReport = actions.crashReport()
        status = gathered
    }

    // MARK: Devices

    private enum State { case good, attention, unknown }

    private var macState: State { status.map { _ in actions.crashReport() == nil ? .good : .attention } ?? .unknown }
    private var miniState: State {
        guard let status else { return .unknown }
        return status.mini.reachable && status.isCurrent(status.mini.commit) != false ? .good : .attention
    }
    private var phoneState: State {
        guard let status else { return .unknown }
        let fresh = status.phoneLog.map { Date().timeIntervalSince($0) < 86_400 } ?? false
        return fresh && status.isCurrent(status.phoneCommit) != false ? .good : .attention
    }

    private func version(_ commit: String?) -> String {
        guard let commit else { return "—" }
        switch status?.isCurrent(commit) {
        case true: return "\(short(commit)) · current"
        case false: return "\(short(commit)) · not \(short(status?.head))"
        default: return short(commit)
        }
    }

    private func deviceCard<Facts: View>(_ name: String, symbol: String, state: State, @ViewBuilder facts: () -> Facts) -> some View {
        Button { navigation.section = .system } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
                    Text(name).font(.headline)
                    Spacer()
                    HStack(spacing: 6) {
                        Dot(color: state == .good ? .mint : state == .attention ? .amber : .gray)
                        Text(state == .good ? "Well" : state == .attention ? "Look" : "…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) { facts() }
            }
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Today

    private var todayRow: [String: Any] { (metrics["days"] as? [[String: Any]])?.last ?? [:] }

    private func today(_ key: String) -> String? {
        guard let n = todayRow[key] as? NSNumber else { return nil }
        return n.stringValue
    }

    private var dictationToday: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Dictation today", link: "All dictations") { navigation.section = .dictations }
            HStack(alignment: .top, spacing: 12) {
                BigNumber(value: today("dictations") ?? "—", label: "dictations")
                BigNumber(value: today("dictated_words") ?? "—", label: "words")
                BigNumber(value: (todayRow["latency_median"] as? Double).map { String(format: "%.1f s", $0) } ?? "—", label: "release to text, median")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recent, id: \.dir) { entry in
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(entry.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                        Text(entry.app).foregroundStyle(.secondary).frame(width: 90, alignment: .leading).lineLimit(1)
                        Text(entry.summary).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.callout)
                    .padding(.vertical, 8)
                }
            }
        }
        .card(padding: 18)
    }

    private var typingToday: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Typing today", link: "Progress") { navigation.section = .progress }
            HStack(alignment: .top, spacing: 12) {
                BigNumber(value: today("typed_words") ?? "—", label: "words on the iPhone")
                BigNumber(value: today("autocorrected") ?? "—", label: "autocorrected")
                BigNumber(value: today("undone") ?? "—", label: "taken back")
            }
            Divider()
            Toggle("Switch a word typed in the wrong layout on the Mac", isOn: $autoLayout)
                .font(.callout)
            Text("Typing on the Mac isn't counted here yet.").font(.caption).foregroundStyle(.secondary)
        }
        .card(padding: 18)
    }

    // MARK: Needs you

    private struct Issue: Identifiable {
        let id: String
        let title: String
        let detail: String
        var action: (String, () -> Void)?
    }

    private var issues: [Issue] {
        guard let status else { return [] }
        var list: [Issue] = []
        if let report = status.crashReport {
            list.append(Issue(id: "crash", title: "Sweetch crashed last run", detail: report.lastPathComponent,
                              action: ("Show report", actions.showCrashReport)))
        }
        if !status.mini.reachable {
            list.append(Issue(id: "mini", title: "The Mac mini doesn't answer", detail: "The iPhone's dictations go nowhere while it's away."))
        } else if status.isCurrent(status.mini.commit) == false {
            list.append(Issue(id: "mini-build", title: "The Mac mini runs \(short(status.mini.commit))",
                              detail: "Here it's \(short(status.head)); it updates itself from main every five minutes."))
        }
        if status.isCurrent(status.phoneCommit) == false {
            list.append(Issue(id: "phone-build", title: "The iPhone runs \(short(status.phoneCommit))", detail: "Here it's \(short(status.head))."))
        }
        if let last = status.phoneLog, Date().timeIntervalSince(last) > 86_400 {
            list.append(Issue(id: "phone-log", title: "No keyboard log from the iPhone since \(ago(last))",
                              detail: "A VPN in the way, or Tailscale off on the phone."))
        }
        if let sync = status.sync, !sync.ok || (sync.date.map { Date().timeIntervalSince($0) > 1800 } ?? true) {
            list.append(Issue(id: "sync", title: "Sync with the Mac mini: \(sync.line)", detail: "Last tried \(ago(sync.date))."))
        }
        if !Watchdog.isInstalled {
            list.append(Issue(id: "watchdog", title: "The watchdog is off", detail: "Nothing restarts sweetch if it crashes.",
                              action: ("Turn on", { Watchdog.install() })))
        }
        return list
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: "Needs you", link: "System") { navigation.section = .system }
            if status == nil {
                ProgressView().controlSize(.small)
            } else if issues.isEmpty {
                HStack(spacing: 8) { Dot(color: .mint); Text("Nothing — all three are well.").foregroundStyle(.secondary) }
            }
            ForEach(issues) { issue in
                HStack(alignment: .top, spacing: 10) {
                    Dot(color: .amber).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.callout.weight(.semibold))
                        Text(issue.detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if let (label, act) = issue.action { Button(label, action: act) }
                }
                .padding(.vertical, 4)
            }
        }
        .card(padding: 18)
    }

    // MARK: Models

    private var llm: [String: Any] { metrics["llm"] as? [String: Any] ?? [:] }

    private var models: some View {
        Button { navigation.section = .costs } label: {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: "Models")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(dollars(llm["today"])).font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("today · \(dollars(llm["week"])) this week").foregroundStyle(.secondary)
                }
                let days = (llm["days"] as? [[String: Any]] ?? []).compactMap { d -> (Date, Double)? in
                    guard let day = (d["day"] as? String).flatMap(dayFormat.date(from:)) else { return nil }
                    return (day, (d["cost"] as? NSNumber)?.doubleValue ?? 0)
                }
                Chart(days, id: \.0) { day in
                    BarMark(x: .value("Day", day.0, unit: .day), y: .value("Cost", day.1))
                        .foregroundStyle(Calendar.current.isDateInToday(day.0) ? Color.mint : Color.secondary.opacity(0.45))
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.day().month()) } }
                .frame(height: 70)
                Text("Two weeks, a bar a day · click for the details").font(.caption).foregroundStyle(.secondary)
            }
            .card(padding: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Dictations

/// Every dictation, newest first, with search and the device it came from; the one chosen in full
/// — what was typed, each listening, the model's settling, what the user made of it.
private struct DictationsPane: View {
    let actions: AppActions
    @State private var entries: [DictationsWindow.Entry] = []
    @State private var selected: URL?
    @State private var query = ""
    @State private var source = "All"
    @State private var sound: NSSound?

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    static func load(limit: Int) -> [DictationsWindow.Entry] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(limit).map { dir in
            let session = DictationsWindow.Entry(dir: dir, date: Date(), session: [:]).json("session.json")
            return DictationsWindow.Entry(dir: dir, date: folderFormatter.date(from: dir.lastPathComponent) ?? .distantPast, session: session)
        }
    }

    private var shown: [DictationsWindow.Entry] {
        entries.filter { e in
            let phone = e.session["device"] as? String == "iPhone"
            let fits = source == "All" || (source == "iPhone") == phone
            return fits && (query.isEmpty || e.summary.localizedCaseInsensitiveContains(query) || e.app.localizedCaseInsensitiveContains(query))
        }
    }

    private var entry: DictationsWindow.Entry? { entries.first { $0.dir == selected } }

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                TextField("Search what you said", text: $query).textFieldStyle(.roundedBorder)
                Picker("", selection: $source) { ForEach(["All", "Mac", "iPhone"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).labelsHidden()
                List(shown, id: \.dir, selection: $selected) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(e.date.formatted(Calendar.current.isDateInToday(e.date) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))
                            Text(e.app)
                            Spacer()
                            if e.session["device"] as? String == "iPhone" { Image(systemName: "iphone") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(e.summary).lineLimit(2).foregroundStyle(e.isHandoff ? .secondary : .primary)
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }
            .padding([.top, .leading, .trailing], 12)
            .frame(minWidth: 260, idealWidth: 340, maxWidth: 480)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Button("Play", systemImage: "play.fill") { play() }
                        .disabled(entry.map { !FileManager.default.fileExists(atPath: $0.dir.appendingPathComponent("recording.wav").path) } ?? true)
                    Button("Show in Finder", systemImage: "folder") { entry.map { NSWorkspace.shared.activateFileViewerSelecting([$0.dir]) } }
                        .disabled(entry == nil)
                    Spacer()
                    Button("Forget the last dictation", systemImage: "trash") { actions.forgetLastDictation() }
                }
                .padding(12)
                Divider()
                DetailText(text: entry.map(DetailWriter.write) ?? NSAttributedString())
            }
            .frame(minWidth: 380, maxWidth: .infinity)
        }
        .background(Color.grouped)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: DictationStore.changed)) { _ in reload() }
        .onDisappear { sound?.stop() }
    }

    private func reload() {
        entries = Self.load(limit: 1000)
        if selected == nil || !entries.contains(where: { $0.dir == selected }) { selected = entries.first?.dir }
    }

    private func play() {
        guard let wav = entry?.dir.appendingPathComponent("recording.wav") else { return }
        sound?.stop()
        sound = NSSound(contentsOf: wav, byReference: true)
        sound?.play()
    }
}

/// The dictation's detail as the Dictations window writes it, selectable.
private struct DetailText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 18, height: 16)
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.textStorage?.isEqual(to: text) == false else { return }
        view.textStorage?.setAttributedString(text)
        view.scrollToBeginningOfDocument(nil)
    }
}

// MARK: - Words & names

private struct WordsPane: View {
    let actions: AppActions
    @State private var glossary = ""
    @State private var persona = ""
    @State private var savedGlossary = ""
    @State private var savedPersona = ""

    var body: some View {
        Page(title: "Words & names", subtitle: "What dictation and correction keep as they are") {
            Button("Refine from history", systemImage: "sparkles") { actions.refineDictionary() }
                .help("Ask the model which names and terms from recent dictations to keep")
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)], spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: "Your words")
                    Text("One a line: names, terms, words spelled your way. Heard close to one of these, dictation writes it so.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $glossary).font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 320).scrollContentBackground(.hidden)
                        .padding(6).background(Color.grouped, in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Save") {
                            try? glossary.write(to: AppSupport.glossary, atomically: true, encoding: .utf8)
                            savedGlossary = glossary
                        }
                        .disabled(glossary == savedGlossary)
                        Text("\(glossary.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count) words")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .card(padding: 18)
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(title: "Who you are")
                    Text("For the models settling a dictation: your name, what you do, who you write to.")
                        .font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $persona)
                        .frame(minHeight: 320).scrollContentBackground(.hidden)
                        .padding(6).background(Color.grouped, in: RoundedRectangle(cornerRadius: 8))
                    Button("Save") {
                        try? persona.write(to: AppSupport.persona, atomically: true, encoding: .utf8)
                        savedPersona = persona
                    }
                    .disabled(persona == savedPersona)
                }
                .card(padding: 18)
            }
        }
        .task {
            if !FileManager.default.fileExists(atPath: AppSupport.glossary.path) { Glossary.add([]) }
            glossary = (try? String(contentsOf: AppSupport.glossary, encoding: .utf8)) ?? ""
            _ = Persona.text()
            persona = (try? String(contentsOf: AppSupport.persona, encoding: .utf8)) ?? ""
            (savedGlossary, savedPersona) = (glossary, persona)
        }
    }
}

// MARK: - Typing

private struct TypingPane: View {
    let actions: AppActions
    @EnvironmentObject private var navigation: MainNavigation
    @AppStorage("autoLayout") private var autoLayout = true
    @State private var remaps = ""
    @State private var savedRemaps = ""
    @State private var week: [String: Any] = [:]

    var body: some View {
        Page(title: "Typing", subtitle: "On the Mac and on the iPhone's keyboard") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)], spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "On the Mac")
                    Toggle("Switch a word typed in the wrong layout as the space after it comes", isOn: $autoLayout)
                    Text("⌥Space right after takes it back and keeps those words as typed.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    ForEach(actions.hotkeys, id: \.0) { key, what in Fact(label: what, value: key) }
                    Button("Detect a key…") { actions.detectKey() }
                        .help("The next key pressed is shown, not typed — for writing a remap")
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "The iPhone's keyboard, this week", link: "Progress") { navigation.section = .progress }
                    HStack(alignment: .top, spacing: 12) {
                        BigNumber(value: number("typed_words", "%.0f"), label: "words typed")
                        BigNumber(value: number("good_autocorrect_per_100", "%.1f"), label: "autocorrected per 100, kept")
                        BigNumber(value: number("fixes_per_100", "%.1f"), label: "fixed by hand per 100")
                    }
                    HStack(alignment: .top, spacing: 12) {
                        BigNumber(value: percent("suggestion_share"), label: "words from suggestions")
                        BigNumber(value: number("typos_left_per_100", "%.1f"), label: "typos left per 100")
                        BigNumber(value: percent("autocorrect_undone_rate"), label: "autocorrections taken back")
                    }
                }
                .card(padding: 18)
            }

            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Key remaps")
                TextEditor(text: $remaps).font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 220).scrollContentBackground(.hidden)
                    .padding(6).background(Color.grouped, in: RoundedRectangle(cornerRadius: 8))
                Button("Save") {
                    try? remaps.write(to: AppSupport.remaps, atomically: true, encoding: .utf8)
                    savedRemaps = remaps
                    actions.reloadRemaps()
                }
                .disabled(remaps == savedRemaps)
            }
            .card(padding: 18)
        }
        .task {
            actions.reloadRemaps()   // writes the default rules if the file is missing
            remaps = (try? String(contentsOf: AppSupport.remaps, encoding: .utf8)) ?? ""
            savedRemaps = remaps
            week = await Task.detached { Stats.currentMetrics() }.value["week"] as? [String: Any] ?? [:]
        }
    }

    private func number(_ key: String, _ format: String) -> String {
        (week[key] as? NSNumber).map { String(format: format, $0.doubleValue) } ?? "—"
    }

    private func percent(_ key: String) -> String {
        (week[key] as? NSNumber).map { "\(Int(($0.doubleValue * 100).rounded()))%" } ?? "—"
    }
}

// MARK: - Progress

private struct ProgressPane: View {
    @State private var view = "Statistics"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $view) { ForEach(["Statistics", "Insights"], id: \.self) { Text($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                .padding(.vertical, 10)
            switch view {
            case "Insights": InsightsView(source: { await Task.detached { Stats.currentInsights() }.value })
            default: MetricsView(source: { await Task.detached { Stats.currentMetrics() }.value })
            }
        }
        .background(Color.grouped)
    }
}

// MARK: - Costs

/// What the models cost: a bar a day, a week or a month, by what for; the sums for the time shown
/// by purpose, model and device.
private struct CostsPane: View {
    private struct Day {
        let date: Date
        let cost: Double
        let calls: Int
        let byPurpose: [String: Double]
        let byModel: [String: Double]
        let byDevice: [String: Double]
    }

    private struct Bar: Identifiable {
        let start: Date
        let purpose: String
        let cost: Double
        var id: String { "\(start.timeIntervalSince1970)|\(purpose)" }
    }

    enum Scale: String, CaseIterable { case days = "Days", weeks = "Weeks", months = "Months" }

    @State private var days: [Day] = []
    @State private var scale = Scale.days
    @State private var counted: Date?

    private var component: Calendar.Component {
        switch scale { case .days: .day; case .weeks: .weekOfYear; case .months: .month }
    }

    /// What the chart spans: a month of days, four months of weeks, every month kept — to the end
    /// of today's day, week or month.
    private var span: ClosedRange<Date> {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let end = calendar.dateInterval(of: component, for: today)!.end
        switch scale {
        case .days: return calendar.date(byAdding: .day, value: -29, to: today)!...end
        case .weeks: return calendar.dateInterval(of: .weekOfYear, for: calendar.date(byAdding: .weekOfYear, value: -15, to: today)!)!.start...end
        case .months:
            let first = days.first?.date ?? today
            return calendar.dateInterval(of: .month, for: min(first, calendar.date(byAdding: .month, value: -5, to: today)!))!.start...end
        }
    }

    private var shown: [Day] { days.filter { span.contains($0.date) } }

    private var bars: [Bar] {
        let calendar = Calendar.current
        var sums: [Date: [String: Double]] = [:]
        for day in shown {
            let start = calendar.dateInterval(of: component, for: day.date)?.start ?? day.date
            for (purpose, cost) in day.byPurpose { sums[start, default: [:]][purpose, default: 0] += cost }
        }
        return sums.flatMap { start, purposes in purposes.map { Bar(start: start, purpose: $0.key, cost: $0.value) } }
            .sorted { ($0.start, $0.purpose) < ($1.start, $1.purpose) }
    }

    private func total(_ key: KeyPath<Day, [String: Double]>) -> [(String, Double)] {
        var sums: [String: Double] = [:]
        for day in shown { for (k, v) in day[keyPath: key] { sums[k, default: 0] += v } }
        return sums.sorted { $0.value > $1.value }
    }

    var body: some View {
        Page(title: "Costs", subtitle: "What the models cost, settling dictations and the rest") {
            Picker("", selection: $scale) { ForEach(Scale.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
        } content: {
            let sum = shown.reduce(0) { $0 + $1.cost }
            let calls = shown.reduce(0) { $0 + $1.calls }
            let spanDays = max(1, (Calendar.current.dateComponents([.day], from: shown.first?.date ?? Date(), to: Date()).day ?? 0) + 1)
            HStack(alignment: .top, spacing: 12) {
                BigNumber(value: dollars(sum), label: scale == .days ? "the last 30 days" : scale == .weeks ? "the last 16 weeks" : "everything kept")
                BigNumber(value: dollars(sum / Double(spanDays)), label: "a day, on average")
                BigNumber(value: dollars(days.last { Calendar.current.isDateInToday($0.date) }?.cost ?? 0), label: "today")
                BigNumber(value: "\(calls)", label: "calls")
            }
            .card(padding: 18)

            VStack(alignment: .leading, spacing: 10) {
                Chart(bars) { bar in
                    BarMark(x: .value("When", bar.start, unit: component), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("For", bar.purpose))
                }
                .chartXScale(domain: span)
                .chartXAxis {
                    switch scale {
                    case .days: AxisMarks(values: .stride(by: .day, count: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month()) }
                    case .weeks: AxisMarks(values: .stride(by: .weekOfYear, count: 2)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.day().month()) }
                    case .months: AxisMarks(values: .stride(by: .month)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)) }
                    }
                }
                .chartYAxis { AxisMarks { value in AxisGridLine(); AxisValueLabel { Text(dollars(value.as(Double.self))) } } }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 280)
                if let counted { Text("Counted \(ago(counted))").font(.caption).foregroundStyle(.secondary) }
            }
            .card(padding: 18)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)], spacing: 16) {
                breakdown("By purpose", total(\.byPurpose), of: sum)
                breakdown("By model", total(\.byModel), of: sum)
                breakdown("By device", total(\.byDevice).map { ($0.0 == "iphone" ? "iPhone" : "Macs", $0.1) }, of: sum)
            }
        }
        .task { await load() }
    }

    private func breakdown(_ title: String, _ rows: [(String, Double)], of sum: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: title)
            ForEach(rows, id: \.0) { name, cost in
                VStack(alignment: .leading, spacing: 4) {
                    Fact(label: name, value: dollars(cost))
                    GeometryReader { g in
                        Capsule().fill(Color.mint.opacity(0.7))
                            .frame(width: max(2, g.size.width * (sum > 0 ? cost / sum : 0)), height: 4)
                    }
                    .frame(height: 4)
                }
            }
            if rows.isEmpty { Text("Nothing yet").foregroundStyle(.secondary) }
        }
        .card(padding: 18)
    }

    private func load() async {
        let llm = await Task.detached { Stats.currentMetrics() }.value["llm"] as? [String: Any] ?? [:]
        func doubles(_ any: Any?) -> [String: Double] {
            (any as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
        }
        days = (llm["history"] as? [[String: Any]] ?? []).compactMap { d in
            guard let date = (d["day"] as? String).flatMap(dayFormat.date(from:)) else { return nil }
            return Day(date: date, cost: (d["cost"] as? NSNumber)?.doubleValue ?? 0, calls: d["calls"] as? Int ?? 0,
                       byPurpose: doubles(d["by_purpose"]), byModel: doubles(d["by_model"]), byDevice: doubles(d["by_device"]))
        }
        counted = Stats.countedAt
    }
}

// MARK: - System

/// The three devices: which build each runs, what runs by itself and how it last went, and what
/// keeps sweetch running here.
private struct SystemPane: View {
    @State private var status: SystemStatus?

    var body: some View {
        Page(title: "System", subtitle: "The three devices, and what keeps them in step") {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await load() } }
        } content: {
            Text("Versions").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
                version("This MacBook", status?.macCommit, note: "checked out here: \(short(status?.head))")
                version("Mac mini", status?.mini.reachable == true ? status?.mini.commit : nil,
                        note: status?.mini.reachable == true ? "updates itself from main" : "doesn't answer")
                version("iPhone app + keyboard", status?.phoneCommit, note: "as its keyboard last said")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { Dot(color: .gray); Text("Keyboard's words").font(.headline) }
                    Text(status?.keyboardWords?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    Text("Lexicon built, then installed with the app").font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }

            Text("Runs by itself").font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], spacing: 12) {
                routine("Sync with the Mac mini", "Recordings, logs, model costs both ways; a forgotten dictation stays gone on both.",
                        every: "every 5 min", last: status?.sync.map { "\($0.line) · \(ago($0.date))" } ?? "—", ok: status?.sync?.ok)
                routine("The Mac mini updates itself", "Builds main when it changes, swaps the server in at a quiet moment, rolls back if it fails.",
                        every: "every 5 min", last: status.map { $0.mini.reachable ? "\($0.mini.commit.map(short) ?? "a build from before versions"), idle \(($0.mini.idle ?? 0) / 60) min" : "doesn't answer" } ?? "—",
                        ok: status.map { $0.mini.reachable && $0.isCurrent($0.mini.commit) != false })
                routine("The iPhone sends its keyboard log", "To whichever Mac it reaches — over Tailscale, or the home network.",
                        every: "as the keyboard closes", last: ago(status?.phoneLog),
                        ok: status?.phoneLog.map { Date().timeIntervalSince($0) < 86_400 })
                routine("Watchdog", "Restarts sweetch after a crash, and the microphone when it's lost.",
                        every: "always", last: Watchdog.isInstalled ? "on" : "off", ok: Watchdog.isInstalled)
                routine("Statistics", "Counted in the background, only what changed, so Progress opens at once.",
                        every: "every 5 min, and after a dictation", last: ago(Stats.countedAt), ok: Stats.countedAt != nil)
            }

            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Running here")
                Toggle("Start at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in _ = try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }))
                Toggle("Restart on crash (watchdog)", isOn: Binding(
                    get: { Watchdog.isInstalled },
                    set: { on in if on { Watchdog.install() } else { Watchdog.uninstall() } }))
                Divider()
                Button("Pull the keyboard's log off the iPhone") { runPhoneLogs() }
                    .help("Over the cable, when the phone reaches no Mac by itself — Tailscale off, a VPN in the way")
            }
            .card(padding: 18)
        }
        .task { await load() }
    }

    private func load() async { status = await SystemStatus.gather() }

    private func version(_ name: String, _ commit: String?, note: String) -> some View {
        let current = status?.isCurrent(commit)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Dot(color: current == true ? .mint : current == false ? .amber : .gray)
                Text(name).font(.headline)
            }
            Text(commit.map { "\(short($0))\(current == true ? " · current" : current == false ? " · behind" : "")" } ?? "—")
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
        .card()
    }

    private func routine(_ name: String, _ what: String, every: String, last: String, ok: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Dot(color: ok == true ? .mint : ok == false ? .amber : .gray)
                Text(name).font(.headline)
            }
            Text(what).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(every)
                Spacer()
                Text(last).multilineTextAlignment(.trailing)
            }
            .font(.caption)
        }
        .card()
    }

    private func runPhoneLogs() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [SystemStatus.repo.appendingPathComponent("Tools/phone-logs.sh").path]
        task.environment = ["PHONE_ID": "00008150-000034D81E47401C", "PATH": "/usr/bin:/bin:/usr/sbin"]
        try? task.run()
    }
}

// MARK: - Screenshots

private struct ScreenshotsPane: View {
    let actions: AppActions
    @State private var shots: [URL] = []

    var body: some View {
        Page(title: "Screenshots") {
            HStack {
                Button("New screenshot", systemImage: "camera.viewfinder") { actions.captureScreenshot() }
                Button("Whole screen") { actions.captureFullScreen() }
                Button("Open folder") { NSWorkspace.shared.open(Screenshots.recent(limit: 1).first?.deletingLastPathComponent() ?? AppSupport.dir) }
                Button("Refresh", systemImage: "arrow.clockwise") { shots = Screenshots.recent(limit: 60) }.labelStyle(.iconOnly)
            }
        } content: {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(shots, id: \.self) { url in
                    Button { NSWorkspace.shared.open(url) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let image = Screenshots.thumbnail(for: url, height: 130) {
                                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 130)
                            }
                            Text(Screenshots.modified(url).formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .card(padding: 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task { shots = Screenshots.recent(limit: 60) }
    }
}

// MARK: - Settings

private struct SettingsPane: View {
    let actions: AppActions
    @AppStorage("dictationEnabled") private var dictation = true
    @AppStorage("dictationServerEnabled") private var server = false
    @AppStorage("wordMenu") private var wordMenu = true
    @AppStorage("logText") private var logText = false
    @State private var incognito = Privacy.incognito

    var body: some View {
        Form {
            Section("Dictation") {
                Toggle("Dictation (hold Space)", isOn: $dictation)
                    .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
                Text("Hold Space in a text field and speak; Claude desktop and Claude Code keep their own dictation, heard alongside.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Word menu: click a dictated word for what else it could be", isOn: $wordMenu)
                Toggle("Dictation server for the iPhone, on this Mac", isOn: $server)
                    .onChange(of: server) { _, on in actions.setServer(on) }
            }
            Section("Privacy") {
                Toggle("Incognito", isOn: $incognito)
                    .onChange(of: incognito) { _, on in actions.setIncognito(on) }
                Text("Nothing recorded, captured, sent to a model or kept — dictation and corrections off, layout switching on. Private browser windows, password fields and password managers are private by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Private right now", value: actions.privateNow() ?? "no")
                Button("Forget the last dictation") { actions.forgetLastDictation() }
                Text("Out of the history here and on the Mac mini; kept aside on this Mac for 30 days, then gone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tracing") {
                Toggle("Text in sweetch's log (for tracing a problem)", isOn: $logText)
                    .onChange(of: logText) { _, _ in Privacy.refreshLogText() }
            }
        }
        .formStyle(.grouped)
    }
}
