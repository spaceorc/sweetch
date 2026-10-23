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
    var showDictations: () -> Void
    var detectKey: () -> Void
    var refineDictionary: () -> Void
    var showCrashReport: () -> Void
    var reloadRemaps: () -> Void
    var privateNow: () -> String?
    var crashReport: () -> URL?
    var hotkeys: [(String, String)]
}

/// Sweetch's own window: everything it does, what it counts and every setting in one place — the
/// menu bar keeps only what's wanted at a glance. The statistics are the iPhone's screens
/// (Views/), counted here.
final class MainWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    var onClose: (() -> Void)?

    init(actions: AppActions, section: MainView.Section = .overview) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Sweetch"
        window.contentViewController = NSHostingController(rootView: MainView(actions: actions, section: section))
        window.setContentSize(NSSize(width: 980, height: 680))
        window.contentMinSize = NSSize(width: 820, height: 560)
        window.setFrameAutosaveName("sweetch.main")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    func show(_ section: MainView.Section? = nil) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    /// `sweetch --render-main <section> <out.png>`: the window, dark, drawn into a PNG once its
    /// numbers have loaded — for looking at a section without putting it on screen.
    static func render(_ section: String, to url: URL) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        let none = AppActions(setServer: { _ in }, setIncognito: { _ in }, forgetLastDictation: {}, captureScreenshot: {},
                              captureFullScreen: {}, showDictations: {}, detectKey: {}, refineDictionary: {}, showCrashReport: {},
                              reloadRemaps: {}, privateNow: { nil }, crashReport: { nil },
                              hotkeys: [("⌥Space", "Put the last words in the other layout"), ("⌘Space", "Switch the layout")])
        let main = MainWindow(actions: none, section: MainView.Section(rawValue: section) ?? .overview)
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
        case overview = "Overview", statistics = "Statistics", insights = "Insights", dictation = "Dictation",
             typing = "Typing", dictionary = "Dictionary", screenshots = "Screenshots", privacy = "Privacy"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.33percent"
            case .statistics: "chart.bar.xaxis"
            case .insights: "hand.tap"
            case .dictation: "mic"
            case .typing: "keyboard"
            case .dictionary: "character.book.closed"
            case .screenshots: "camera.viewfinder"
            case .privacy: "eye.slash"
            }
        }
    }

    let actions: AppActions
    @State private var section: Section?

    init(actions: AppActions, section: Section = .overview) {
        self.actions = actions
        _section = State(initialValue: section)
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch section ?? .overview {
            case .overview: OverviewPane(actions: actions)
            case .statistics: MetricsView(source: { await Task.detached { Metrics.compute() }.value })
            case .insights: InsightsView(source: { await Task.detached { Insights.compute() }.value })
            case .dictation: DictationPane(actions: actions)
            case .typing: TypingPane(actions: actions)
            case .dictionary: DictionaryPane(actions: actions)
            case .screenshots: ScreenshotsPane(actions: actions)
            case .privacy: PrivacyPane(actions: actions)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    let actions: AppActions
    @AppStorage("dictationEnabled") private var dictation = true
    @AppStorage("dictationServerEnabled") private var server = false
    @State private var incognito = Privacy.incognito
    @State private var spend: [String: Any] = [:]
    @State private var phoneLog: Date?
    @State private var lastSync: String?

    var body: some View {
        Form {
            Section("Now") {
                Toggle("Dictation (hold Space)", isOn: $dictation)
                    .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
                Toggle("Dictation server for the iPhone", isOn: $server)
                    .onChange(of: server) { _, on in actions.setServer(on) }
                Toggle("Incognito", isOn: $incognito)
                    .onChange(of: incognito) { _, on in actions.setIncognito(on) }
                LabeledContent("Private right now", value: actions.privateNow() ?? "no")
                if let report = actions.crashReport() {
                    LabeledContent("Crashed last run") { Button("Show Report") { actions.showCrashReport() } }
                        .help(report.lastPathComponent)
                }
            }
            Section("Models") {
                LabeledContent("Today", value: dollars(spend["today"]))
                LabeledContent("Last 7 days", value: "\(dollars(spend["week"])) · \((spend["week_calls"] as? Int) ?? 0) calls")
                ForEach(Array((spend["by_purpose"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, row in
                    LabeledContent(row["name"] as? String ?? "?", value: "\(dollars(row["cost"])) · \(row["calls"] as? Int ?? 0) calls")
                }
                LabeledContent("All kept", value: dollars(spend["all"]))
            }
            Section("Devices") {
                LabeledContent("iPhone keyboard's log, last", value: phoneLog.map { $0.formatted(.relative(presentation: .named)) } ?? "never")
                LabeledContent("Sync with the Mac mini", value: lastSync ?? "—")
                Button("Pull the keyboard's log off the iPhone (make phone-logs)") { runPhoneLogs() }
                    .help("When the phone reaches no Mac by itself — Tailscale off, a VPN in the way")
            }
            Section("Running") {
                Toggle("Start at login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in _ = try? (on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()) }))
                Toggle("Restart on crash (watchdog)", isOn: Binding(
                    get: { Watchdog.isInstalled },
                    set: { on in if on { Watchdog.install() } else { Watchdog.uninstall() } }))
            }
        }
        .formStyle(.grouped)
        .task {
            spend = await Task.detached { Metrics.llmSummary() }.value
            let keyboard = AppSupport.dir.appendingPathComponent("keyboard")
            phoneLog = ((try? FileManager.default.contentsOfDirectory(at: keyboard, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
            let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/sweetch-sync.log")
            lastSync = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
        }
    }

    private func runPhoneLogs() {
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        let script = repo.appendingPathComponent("Tools/phone-logs.sh")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = [script.path]
        task.environment = ["PHONE_ID": "00008150-000034D81E47401C", "PATH": "/usr/bin:/bin:/usr/sbin"]
        try? task.run()
    }
}

// MARK: - Dictation

private struct DictationPane: View {
    let actions: AppActions
    @AppStorage("dictationEnabled") private var dictation = true
    @AppStorage("dictationServerEnabled") private var server = false
    @AppStorage("wordMenu") private var wordMenu = true
    @State private var recent: [(String, String, String)] = []

    var body: some View {
        Form {
            Section {
                Toggle("Dictation (hold Space)", isOn: $dictation)
                    .onChange(of: dictation) { _, on in if on { Whisper.warmUp() } }
                Text("Hold Space in a text field and speak; Claude desktop and Claude Code keep their own dictation, heard alongside.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Dictation server for the iPhone", isOn: $server)
                    .onChange(of: server) { _, on in actions.setServer(on) }
                Toggle("Word menu: click a dictated word for what else it could be", isOn: $wordMenu)
            }
            Section("Recent dictations") {
                ForEach(Array(recent.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top) {
                        Text(row.0).monospacedDigit().foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(row.1).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        Text(row.2).lineLimit(2)
                    }
                }
                HStack {
                    Button("All dictations…") { actions.showDictations() }
                    Button("Forget the last one") { actions.forgetLastDictation(); load() }
                }
            }
        }
        .formStyle(.grouped)
        .task { load() }
    }

    private func load() {
        let dirs = ((try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(25)
        recent = dirs.compactMap { dir in
            guard let s = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("session.json")))) as? [String: Any] else { return nil }
            let text = s["theirs"] as? String ?? s["text"] as? String ?? ""
            let parse = DateFormatter()
            parse.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let when = parse.date(from: String(dir.lastPathComponent.prefix(19)))?.formatted(.dateTime.day().month(.abbreviated).hour().minute()) ?? ""
            return (when, s["app"] as? String ?? "", text)
        }
    }
}

// MARK: - Typing

private struct TypingPane: View {
    let actions: AppActions
    @AppStorage("autoLayout") private var autoLayout = true
    @State private var remaps = ""

    var body: some View {
        Form {
            Section("Layouts") {
                Toggle("Switch a word typed in the wrong layout as the space after it comes", isOn: $autoLayout)
                Text("The go of typing before it goes along; ⌥Space right after takes it back and keeps those words as typed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keys") {
                ForEach(actions.hotkeys, id: \.0) { key, what in LabeledContent(what, value: key) }
                Button("Detect a key…") { actions.detectKey() }
                    .help("The next key pressed is shown, not typed — for writing a remap")
            }
            Section("Key remaps") {
                TextEditor(text: $remaps).font(.system(size: 12, design: .monospaced)).frame(minHeight: 180)
                Button("Save") {
                    try? remaps.write(to: AppSupport.remaps, atomically: true, encoding: .utf8)
                    actions.reloadRemaps()
                }
            }
        }
        .formStyle(.grouped)
        .task {
            actions.reloadRemaps()   // writes the default rules if the file is missing
            remaps = (try? String(contentsOf: AppSupport.remaps, encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPane: View {
    let actions: AppActions
    @State private var glossary = ""
    @State private var persona = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $glossary).font(.system(size: 12, design: .monospaced)).frame(minHeight: 160)
                HStack {
                    Button("Save") { try? glossary.write(to: AppSupport.glossary, atomically: true, encoding: .utf8) }
                    Button("Refine from history") { actions.refineDictionary() }
                    Button("History in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: AppSupport.history.path) ? AppSupport.history : AppSupport.dir])
                    }
                }
            } header: {
                Text("Dictionary — words kept as they are by correction and dictation")
            }
            Section {
                TextEditor(text: $persona).frame(minHeight: 140)
                Button("Save") { try? persona.write(to: AppSupport.persona, atomically: true, encoding: .utf8) }
            } header: {
                Text("Persona — who you are, for the models")
            }
        }
        .formStyle(.grouped)
        .task {
            if !FileManager.default.fileExists(atPath: AppSupport.glossary.path) { Glossary.add([]) }
            glossary = (try? String(contentsOf: AppSupport.glossary, encoding: .utf8)) ?? ""
            _ = Persona.text()
            persona = (try? String(contentsOf: AppSupport.persona, encoding: .utf8)) ?? ""
        }
    }
}

// MARK: - Screenshots

private struct ScreenshotsPane: View {
    let actions: AppActions
    @State private var shots: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("New screenshot") { actions.captureScreenshot() }
                Button("Whole screen") { actions.captureFullScreen() }
                Button("Open folder") { NSWorkspace.shared.open(Screenshots.recent(limit: 1).first?.deletingLastPathComponent() ?? AppSupport.dir) }
                Spacer()
                Button("Refresh") { shots = Screenshots.recent(limit: 48) }
            }
            .buttonStyle(.bordered)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    ForEach(shots, id: \.self) { url in
                        Button { NSWorkspace.shared.open(url) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                if let image = Screenshots.thumbnail(for: url, height: 110) {
                                    Image(nsImage: image).resizable().scaledToFit().frame(height: 110)
                                }
                                Text(Screenshots.modified(url).formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.grouped)
        .task { shots = Screenshots.recent(limit: 48) }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    let actions: AppActions
    @State private var incognito = Privacy.incognito
    @AppStorage("logText") private var logText = false

    var body: some View {
        Form {
            Section {
                Toggle("Incognito", isOn: $incognito)
                    .onChange(of: incognito) { _, on in actions.setIncognito(on) }
                Text("Nothing recorded, captured, sent to a model or kept — dictation and corrections off, layout switching on. Private browser windows, password fields and password managers are private by themselves.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Private right now", value: actions.privateNow() ?? "no")
            }
            Section {
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

private func dollars(_ value: Any?) -> String {
    let v = (value as? NSNumber)?.doubleValue ?? 0
    return v >= 1 ? String(format: "$%.2f", v) : String(format: "$%.3f", v)
}
