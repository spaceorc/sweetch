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

/// Light, dark, or as the system is — for sweetch's windows and panels; kept in UserDefaults.
enum Appearance: String, CaseIterable {
    case system = "System", light = "Light", dark = "Dark"

    static let key = "appearance"

    static func apply() {
        switch Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Which section the window shows — set from outside too (the menu's "All dictations").
final class MainNavigation: ObservableObject {
    @Published var section: MainView.Section? = .overview
    /// The dictation to show when History opens.
    @Published var dictation: URL?
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
    /// A page of the window.
    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview", dictations = "History", words = "Words & names", typing = "Typing",
             statistics = "Statistics", insights = "Insights", costs = "Costs", screenshots = "Screenshots",
             settings = "General", system = "System"
        var id: String { String(describing: self) }
        var item: Item { Item.allCases.first { $0.sections.contains(self) }! }
    }

    /// A place in the sidebar: one page, or a few side by side, chosen above them.
    enum Item: String, CaseIterable, Identifiable {
        case overview = "Overview", dictation = "Dictation", typing = "Typing", progress = "Progress",
             screenshots = "Screenshots", settings = "Settings"
        var id: String { rawValue }
        var sections: [Section] {
            switch self {
            case .overview: [.overview]
            case .dictation: [.dictations, .words]
            case .typing: [.typing]
            case .progress: [.statistics, .insights, .costs]
            case .screenshots: [.screenshots]
            case .settings: [.settings, .system]
            }
        }
        /// The badge's colour, as System Settings colours its rows.
        var color: Color {
            switch self {
            case .overview: Color(red: 0.16, green: 0.62, blue: 0.62)
            case .dictation: .red
            case .typing: .blue
            case .progress: .purple
            case .screenshots: .indigo
            case .settings: .gray
            }
        }
        var symbol: String {
            switch self {
            case .overview: "house.fill"
            case .dictation: "mic.fill"
            case .typing: "keyboard"
            case .progress: "chart.bar.fill"
            case .screenshots: "camera.viewfinder"
            case .settings: "gearshape.fill"
            }
        }
    }

    let actions: AppActions
    @EnvironmentObject private var navigation: MainNavigation

    private var item: Binding<Item?> {
        Binding(get: { (navigation.section ?? .overview).item },
                set: { navigation.section = $0?.sections.first })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: item) {
                ForEach([Item.overview, .dictation, .typing, .progress, .screenshots]) { i in
                    badge(i).padding(.vertical, 3).tag(i)
                }
            }
            .safeAreaInset(edge: .top) { emblem }
            .safeAreaInset(edge: .bottom) {
                Button { navigation.section = .settings } label: { badge(.settings) }
                    .buttonStyle(.plain).clickable()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.bottom, 14)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
        } detail: {
            let section = navigation.section ?? .overview
            Group {
                switch section {
                case .overview: OverviewPane(actions: actions)
                case .dictations: DictationsPane(actions: actions)
                case .words: WordsPane(actions: actions)
                case .typing: TypingPane(actions: actions)
                case .statistics: MetricsView(source: { await Task.detached { Stats.currentMetrics() }.value })
                case .insights: InsightsView(source: { await Task.detached { Stats.currentInsights() }.value })
                case .costs: CostsPane()
                case .system: SystemPane()
                case .screenshots: ScreenshotsPane(actions: actions)
                case .settings: SettingsPane(actions: actions)
                }
            }
            .toolbar {
                if section.item.sections.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Picker("", selection: Binding(get: { section }, set: { navigation.section = $0 })) {
                            ForEach(section.item.sections) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                }
            }
            .navigationTitle(section.item.rawValue)
        }
        .tint(.mint)
    }

    /// A place's name by its icon in a coloured rounded square.
    private func badge(_ i: Item) -> some View {
        HStack(spacing: 10) {
            Image(systemName: i.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(i.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(i.rawValue).font(.system(size: 14))
        }
    }

    /// The app's emblem over the list, with its name.
    private var emblem: some View {
        HStack(spacing: 10) {
            if let url = Bundle.main.url(forResource: "emblem", withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().frame(width: 44, height: 44)
                    .shadow(color: .mint.opacity(0.35), radius: 8)
            }
            Text("Sweetch").font(.system(size: 20, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 10)
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
            .padding(.top, 12)
            .padding(.bottom, 28)
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

/// Cards in columns, as many as fit at least `minColumn` wide; each card goes under the shortest
/// column's last, so cards of any height leave no holes, and the columns reflow as the window
/// resizes.
private struct Masonry: Layout {
    var minColumn: CGFloat
    var spacing: CGFloat = 16

    private func columns(_ width: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + spacing) / (minColumn + spacing)))
        return (count, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
    }

    /// Each card's place, and the height of it all.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> ([CGPoint], CGFloat, CGFloat) {
        let (count, column) = columns(width)
        var heights = Array(repeating: CGFloat(0), count: count)
        var places: [CGPoint] = []
        for view in subviews {
            let i = heights.indices.min { heights[$0] < heights[$1] }!
            places.append(CGPoint(x: CGFloat(i) * (column + spacing), y: heights[i]))
            heights[i] += view.sizeThatFits(ProposedViewSize(width: column, height: nil)).height + spacing
        }
        return (places, column, max(0, (heights.max() ?? 0) - spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minColumn * 2 + spacing
        return CGSize(width: width, height: arrange(subviews, width: width).2)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (places, column, _) = arrange(subviews, width: bounds.width)
        for (view, place) in zip(subviews, places) {
            view.place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y),
                       proposal: ProposedViewSize(width: column, height: nil))
        }
    }
}

/// Cards side by side, equal in width and as tall as the tallest, when each gets at least
/// `minChild`; else one under another, full width.
private struct EqualRow: Layout {
    var minChild: CGFloat
    var spacing: CGFloat = 16

    private func plan(_ subviews: Subviews, width: CGFloat) -> (side: Bool, child: CGFloat, height: CGFloat, heights: [CGFloat]) {
        let n = CGFloat(subviews.count)
        let child = (width - spacing * (n - 1)) / n
        if child >= minChild {
            let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: child, height: nil)).height }.max() ?? 0
            return (true, child, h, [])
        }
        let hs = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return (false, width, hs.reduce(0, +) + spacing * (n - 1), hs)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? minChild * CGFloat(subviews.count)
        return CGSize(width: width, height: plan(subviews, width: width).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(subviews, width: bounds.width)
        var y = bounds.minY
        for (i, view) in subviews.enumerated() {
            if p.side {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(i) * (p.child + spacing), y: bounds.minY),
                           proposal: ProposedViewSize(width: p.child, height: p.height))
            } else {
                view.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: p.child, height: p.heights[i]))
                y += p.heights[i] + spacing
            }
        }
    }
}

private extension View {
    /// The pointing hand over what can be clicked.
    func clickable() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }

    func card(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.groupedSecondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct Dot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

/// A heading over a group of cards.
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary)
            .padding(.bottom, -10)
    }
}

private struct CardTitle: View {
    let title: String
    var link: String?
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let link, let action { Button(link, action: action).buttonStyle(.link).clickable() }
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
                pill(incognito ? "Incognito on" : "Incognito", "eye.slash", on: incognito, color: .amber) { incognito.toggle() }
                pill(dictation ? "Dictation on" : "Dictation off", "mic.fill", on: dictation, color: .mint) { dictation.toggle() }
            }
            .onChange(of: incognito) { _, on in actions.setIncognito(on) }
            .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
        } content: {
            // What needs the user comes first, and only when there's something.
            if !issues.isEmpty { needsYou }

            switch Self.variant {
            case "masonry":
                Masonry(minColumn: 250, spacing: 12) { macCard; miniCard; phoneCard }
                Masonry(minColumn: 380) { dictationToday; typingToday; models }
            case "strip":
                devicesStrip
                rows
            default:
                // Rows of cards alike, each row as tall as its tallest; one column when narrow.
                EqualRow(minChild: 240, spacing: 12) { macCard; miniCard; phoneCard }
                rows
            }
        }
        .task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DictationStore.changed)) { _ in recent = finished() }
    }

    /// A switch in the header that shows its state: filled when on.
    private func pill(_ title: String, _ symbol: String, on: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(on ? Color.black.opacity(0.85) : Color.primary)
                .background(on ? AnyShapeStyle(color) : AnyShapeStyle(Color.groupedSecondary), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.12)))
        }
        .buttonStyle(.plain).clickable()
    }

    /// How the cards are laid out — "bento" (rows), "masonry", "strip"; SWEETCH_OVERVIEW picks one
    /// for comparing renders.
    static let variant = ProcessInfo.processInfo.environment["SWEETCH_OVERVIEW"] ?? "strip"

    private var rows: some View {
        VStack(spacing: 16) {
            EqualRow(minChild: 360) { dictationToday; typingToday }
            models
        }
    }

    private var macCard: some View {
        deviceCard("This MacBook", symbol: "laptopcomputer", state: macState) {
            Fact(label: "Dictation · layouts", value: "\(dictation ? "on" : "off") · \(autoLayout ? "switched for you" : "as typed")")
            Fact(label: "Running since", value: launchedAt.formatted(Calendar.current.isDateInToday(launchedAt) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))
            Fact(label: "Build", value: version(status?.macCommit))
        }
    }

    private var miniCard: some View {
        deviceCard("Mac mini", symbol: "macmini", state: miniState) {
            Fact(label: "Heard for the iPhone", value: "\(today("phone_dictations") ?? "—") today")
            Fact(label: "Build", value: status?.mini.reachable == true ? version(status?.mini.commit) : "doesn't answer")
            Fact(label: "Synced with this Mac", value: ago(status?.sync?.date))
        }
    }

    private var phoneCard: some View {
        deviceCard("iPhone", symbol: "iphone", state: phoneState) {
            Fact(label: "Keyboard log came", value: ago(status?.phoneLog))
            Fact(label: "Build", value: version(status?.phoneCommit))
            Fact(label: "Keyboard's words built", value: status?.keyboardWords?.formatted(date: .abbreviated, time: .omitted) ?? "—")
        }
    }

    /// The three devices in one card, side by side — one under another when narrow: each one's
    /// state in a line, amber only where something's wrong.
    private var devicesStrip: some View {
        Button { navigation.section = .system } label: {
            EqualRow(minChild: 230, spacing: 24) {
                stripColumn("This MacBook", "laptopcomputer", macState, macLine)
                stripColumn("Mac mini", "macmini", miniState, miniLine)
                stripColumn("iPhone", "iphone", phoneState, phoneLine)
            }
            .card(padding: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }

    private var macLine: String {
        "\(buildWord(status?.macCommit)) · running since \(launchedAt.formatted(Calendar.current.isDateInToday(launchedAt) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))"
    }

    private var miniLine: String {
        guard let status else { return "…" }
        guard status.mini.reachable else { return "doesn't answer" }
        return "\(buildWord(status.mini.commit)) · synced \(ago(status.sync?.date))"
    }

    private var phoneLine: String {
        guard let status else { return "…" }
        return "\(buildWord(status.phoneCommit)) · log \(ago(status.phoneLog))"
    }

    /// "current", "behind", or "older build" when it doesn't say.
    private func buildWord(_ commit: String?) -> String {
        guard let commit else { return "older build" }
        switch status?.isCurrent(commit) {
        case true: return "current"
        case false: return "behind (\(short(commit)))"
        default: return short(commit)
        }
    }

    private func stripColumn(_ name: String, _ symbol: String, _ state: State, _ line: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(.secondary).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(name).font(.headline)
                    if state == .attention { Dot(color: .amber) }
                }
                Text(line).font(.callout).foregroundStyle(state == .attention ? Color.amber : .secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The last six dictations done — not one still being heard.
    private func finished() -> [DictationsWindow.Entry] {
        Array(DictationsPane.load(limit: 12).filter { !$0.session.isEmpty }.prefix(6))
    }

    private func load() async {
        async let s = SystemStatus.gather()
        metrics = await Task.detached { Stats.currentMetrics() }.value
        recent = finished()
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
        .buttonStyle(.plain).clickable()
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
                BigNumber(value: (todayRow["latency_median"] as? Double).map { String(format: "%.1f s", $0) } ?? "—", label: "typical wait")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(recent, id: \.dir) { entry in
                    Divider()
                    Button {
                        navigation.dictation = entry.dir
                        navigation.section = .dictations
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.date.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                                .foregroundStyle(.secondary).frame(width: 48, alignment: .leading)
                            Text(entry.said).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(entry.app).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .font(.callout)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).clickable()
                }
            }
        }
        .card(padding: 18)
    }

    private var typingToday: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardTitle(title: "Typing today", link: "Statistics") { navigation.section = .statistics }
            if (todayRow["typed_words"] as? Int ?? 0) > 0 {
                HStack(alignment: .top, spacing: 12) {
                    BigNumber(value: today("typed_words") ?? "—", label: "words on the iPhone")
                    BigNumber(value: today("autocorrected") ?? "—", label: "autocorrected")
                    BigNumber(value: today("undone") ?? "—", label: "taken back")
                }
            } else {
                Text("Nothing typed on the iPhone yet today.").foregroundStyle(.secondary)
            }
            // The week, so the card says something on a quiet day too.
            let week = metrics["week"] as? [String: Any] ?? [:]
            Text("THIS WEEK").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(.secondary).padding(.top, 6)
            HStack(alignment: .top, spacing: 12) {
                BigNumber(value: (week["typed_words"] as? NSNumber)?.stringValue ?? "—", label: "words typed")
                BigNumber(value: (week["good_autocorrect_per_100"] as? NSNumber).map { String(format: "%.1f", $0.doubleValue) } ?? "—",
                          label: "autocorrected per 100")
                BigNumber(value: (week["suggestion_share"] as? NSNumber).map { "\(Int(($0.doubleValue * 100).rounded()))%" } ?? "—",
                          label: "from suggestions")
            }
            Spacer(minLength: 0)
            Divider()
            Toggle("Fix words typed in the wrong layout on the Mac", isOn: $autoLayout)
                .toggleStyle(.switch).font(.callout)
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
                Chart(days.suffix(7), id: \.0) { day in
                    BarMark(x: .value("Day", day.0, unit: .day), y: .value("Cost", day.1))
                        .foregroundStyle(Calendar.current.isDateInToday(day.0) ? Color.mint : Color.secondary.opacity(0.45))
                        .cornerRadius(3)
                }
                .chartYAxis(.hidden)
                .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                .frame(height: 56)
            }
            .card(padding: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).clickable()
    }
}

// MARK: - Dictations

/// Every dictation, newest first, with search and the device it came from; the one chosen in full
/// — what was typed, each listening, the model's settling, what the user made of it.
private struct DictationsPane: View {
    let actions: AppActions
    @State private var entries: [DictationsWindow.Entry] = []
    @EnvironmentObject private var navigation: MainNavigation
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
            guard !e.session.isEmpty else { return false }   // still being heard
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
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                List(shown, id: \.dir, selection: $selected) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(e.date.formatted(Calendar.current.isDateInToday(e.date) ? .dateTime.hour().minute() : .dateTime.day().month().hour().minute()))
                            Text(e.isHandoff ? "\(e.app) · its own dictation" : e.app)
                            Spacer()
                            if e.session["device"] as? String == "iPhone" { Image(systemName: "iphone") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(e.said).lineLimit(2)
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
        if let wanted = navigation.dictation {
            selected = wanted
            navigation.dictation = nil
        }
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

    private var words: Int {
        glossary.split(separator: "\n").filter { let t = $0.trimmingCharacters(in: .whitespaces); return !t.isEmpty && !t.hasPrefix("#") }.count
    }

    var body: some View {
        Page(title: "Words & names", subtitle: "What dictation and correction keep as they are") {
            Button("Refine from history", systemImage: "sparkles") { actions.refineDictionary() }
                .help("Ask the model which names and terms from recent dictations to keep")
        } content: {
            EqualRow(minChild: 380) {
                TextCard(title: "Your words", note: "\(words) · one a line: names, terms, words spelled your way",
                         text: $glossary, saved: $savedGlossary, file: AppSupport.glossary)
                TextCard(title: "Who you are", note: "for the models settling a dictation: your name, your work, who you write to",
                         text: $persona, saved: $savedPersona, file: AppSupport.persona)
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

/// A text file edited in place: its title and Save above it (Save only once something changed).
private struct TextCard: View {
    let title: String
    let note: String
    @Binding var text: String
    @Binding var saved: String
    let file: URL
    var onSave: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Button("Save") {
                    try? text.write(to: file, atomically: true, encoding: .utf8)
                    saved = text
                    onSave()
                }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .opacity(text == saved ? 0 : 1)
            }
            Text(note).font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced)).lineSpacing(4)
                .frame(minHeight: 340, maxHeight: .infinity).scrollContentBackground(.hidden)
                .padding(8).background(Color.grouped, in: RoundedRectangle(cornerRadius: 8))
        }
        .card(padding: 18)
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
            EqualRow(minChild: 380) {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "On the Mac")
                    Toggle("Fix words typed in the wrong layout", isOn: $autoLayout).toggleStyle(.switch)
                    Text("Switched as the space after the word comes; ⌥Space right after takes it back and keeps it as typed.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    ForEach(actions.hotkeys, id: \.0) { key, what in Fact(label: what, value: key) }
                    Button("Detect a key…") { actions.detectKey() }
                        .help("The next key pressed is shown, not typed — for writing a remap")
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "The iPhone's keyboard, this week", link: "Statistics") { navigation.section = .statistics }
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

            TextCard(title: "Key remaps", note: "a key for another, in the file's own words — the lines starting with # explain how",
                     text: $remaps, saved: $savedRemaps, file: AppSupport.remaps, onSave: actions.reloadRemaps)
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
        // From the first day anything was spent, if that's within the month — a week at least.
        case .days:
            let first = days.first.map { calendar.startOfDay(for: $0.date) } ?? today
            let from = max(calendar.date(byAdding: .day, value: -29, to: today)!, min(first, calendar.date(byAdding: .day, value: -6, to: today)!))
            return from...end
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
                BigNumber(value: dollars(sum), label: scale == .days ? "these days" : scale == .weeks ? "these weeks" : "everything kept")
                BigNumber(value: dollars(sum / Double(spanDays)), label: "a day, on average")
                BigNumber(value: dollars(days.last { Calendar.current.isDateInToday($0.date) }?.cost ?? 0), label: "today")
                BigNumber(value: "\(calls)", label: "calls to models")
            }
            .card(padding: 18)

            VStack(alignment: .leading, spacing: 10) {
                Chart(bars) { bar in
                    BarMark(x: .value("When", bar.start, unit: component), y: .value("Cost", bar.cost))
                        .foregroundStyle(by: .value("For", bar.purpose))
                }
                .chartForegroundStyleScale(domain: purposes, range: purposes.map(color))
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

            Masonry(minColumn: 260, spacing: 16) {
                breakdown("By purpose", total(\.byPurpose), of: sum, colored: true)
                breakdown("By model", total(\.byModel), of: sum)
                if total(\.byDevice).count > 1 {
                    breakdown("By device", total(\.byDevice).map { ($0.0 == "iphone" ? "iPhone" : "Macs", $0.1) }, of: sum)
                }
            }
        }
        .task { await load() }
    }

    /// Every purpose seen, in one order — the chart's colours and the breakdown's the same.
    private var purposes: [String] { Array(Set(days.flatMap { $0.byPurpose.keys })).sorted() }

    private static let palette: [Color] = [.mint, .blue, .orange, .purple, .pink, .yellow, .teal, .indigo]

    private func color(_ purpose: String) -> Color {
        purposes.firstIndex(of: purpose).map { Self.palette[$0 % Self.palette.count] } ?? .gray
    }

    private func breakdown(_ title: String, _ rows: [(String, Double)], of sum: Double, colored: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: title)
            ForEach(rows, id: \.0) { name, cost in
                VStack(alignment: .leading, spacing: 4) {
                    Fact(label: name, value: dollars(cost))
                    GeometryReader { g in
                        Capsule().fill(colored ? color(name) : Color.secondary.opacity(0.5))
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
            SectionHeader(title: "Versions")
            EqualRow(minChild: 200, spacing: 12) {
                version("This MacBook", status?.macCommit, note: "checked out here: \(short(status?.head))")
                version("Mac mini", status?.mini.reachable == true ? status?.mini.commit : nil,
                        note: status?.mini.reachable == true ? "updates itself from main" : "doesn't answer")
                version("iPhone app + keyboard", status?.phoneCommit, note: "as its keyboard last said")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { Dot(color: .gray); Text("Keyboard dictionary").font(.headline) }
                    Text(status?.keyboardWords?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    Text("built here, installed with the app").font(.caption).foregroundStyle(.secondary)
                }
                .card()
            }

            SectionHeader(title: "Runs by itself")
            VStack(spacing: 0) {
                routine("Sync with the Mac mini", "Recordings, logs, model costs both ways; a forgotten dictation stays gone on both.",
                        every: "every 5 min", last: status?.sync.map { "\($0.line) \(ago($0.date))" } ?? "…", ok: status?.sync?.ok)
                Divider()
                routine("The Mac mini updates itself", "Builds main when it changes, swaps the server in at a quiet moment, rolls back if it fails.",
                        every: "every 5 min", last: status.map { $0.mini.reachable ? ($0.mini.commit.map { "on \(short($0))" } ?? "on an older build") : "doesn't answer" } ?? "…",
                        ok: status.map { $0.mini.reachable && $0.isCurrent($0.mini.commit) != false })
                Divider()
                routine("The iPhone sends its keyboard log", "To whichever Mac it reaches — over Tailscale, or the home network.",
                        every: "as the keyboard closes", last: "came \(ago(status?.phoneLog))",
                        ok: status?.phoneLog.map { Date().timeIntervalSince($0) < 86_400 })
                Divider()
                routine("Watchdog", "Restarts sweetch after a crash, and the microphone when it's lost.",
                        every: "always", last: Watchdog.isInstalled ? "on" : "off", ok: Watchdog.isInstalled)
                Divider()
                routine("Statistics", "Counted in the background, only what changed, so Progress opens at once.",
                        every: "every 5 min, and after a dictation", last: Stats.countedAt.map { "counted \(ago($0))" } ?? "counting…",
                        ok: Stats.countedAt.map { _ in true })
            }
            .card(padding: 6)

            Button("Pull the keyboard's log off the iPhone over the cable") { runPhoneLogs() }
                .help("When the phone reaches no Mac by itself — Tailscale off, a VPN in the way")
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
        HStack(alignment: .top, spacing: 12) {
            Dot(color: ok == true ? .mint : ok == false ? .amber : .gray).padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.headline)
                Text(what).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 2) {
                Text(last).font(.callout)
                Text(every).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
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
                    .buttonStyle(.plain).clickable()
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
    @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
    @State private var incognito = Privacy.incognito

    var body: some View {
        Page(title: "Settings") {
            Masonry(minColumn: 380) {
                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "Dictation")
                    toggle("Dictation — hold Space and speak", $dictation)
                        .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
                    toggle("Word menu — click a dictated word for what else it could be", $wordMenu)
                    toggle("Hear for the iPhone on this Mac too", $server)
                        .onChange(of: server) { _, on in actions.setServer(on) }
                    Text("Claude desktop and Claude Code keep their own dictation, heard alongside.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "Privacy")
                    toggle("Incognito", $incognito)
                        .onChange(of: incognito) { _, on in actions.setIncognito(on) }
                    Text("Nothing recorded, sent to a model or kept. Private browser windows, password fields and password managers are private by themselves.")
                        .font(.callout).foregroundStyle(.secondary)
                    Fact(label: "Private right now", value: actions.privateNow() ?? "no")
                    Button("Forget the last dictation") { actions.forgetLastDictation() }
                        .help("Out of the history here and on the Mac mini; kept aside on this Mac for 30 days, then gone")
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "This Mac")
                    toggle("Start at login", Binding(
                        get: { SMAppService.mainApp.status == .enabled },
                        set: { on in _ = try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }))
                    toggle("Restart on crash (watchdog)", Binding(
                        get: { Watchdog.isInstalled },
                        set: { on in if on { Watchdog.install() } else { Watchdog.uninstall() } }))
                    toggle("Text in sweetch's log, for tracing a problem", $logText)
                        .onChange(of: logText) { _, _ in Privacy.refreshLogText() }
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 12) {
                    CardTitle(title: "Appearance")
                    Picker("", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .onChange(of: appearance) { _, _ in Appearance.apply() }
                }
                .card(padding: 18)
            }
        }
    }

    private func toggle(_ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) { Text(title).frame(maxWidth: .infinity, alignment: .leading) }.toggleStyle(.switch)
    }
}
