import SwiftUI

@main
struct SweetchPhoneApp: App {
    init() {
        LivePreview.prepare()
        Credentials.load()
        PhoneServer.shared.start()   // the keyboard hears from here what the phone heard itself
        Task { if let mac = await Server.reachable() { await Credentials.refresh(from: mac) } }
        _ = PhoneWhisper.shared   // knows from the start whether the app is in front
        // The folder shared with the keyboard, if the signing allows one: a file to show it works.
        if let shared = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.spaceorc.sweetch") {
            try? Data("\(Date())".utf8).write(to: shared.appendingPathComponent("from-app.txt"))
        }
        // What earlier builds traced here (see the keyboard's KeyLog for what's kept now).
        try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("trace.log"))
        // `--check-servers`: which Mac answers, twice, timed — for trying the choice in the simulator.
        if ProcessInfo.processInfo.arguments.contains("--check-servers") {
            Task {
                for _ in 0..<2 {
                    let started = Date()
                    let server = await Server.reachable()
                    print("chose \(server?.address ?? "none") in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                }
                exit(0)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--keyboard-preview") {
                KeyboardPreview()
            } else {
                ContentView()
                    // sweetch://dictate — the keyboard's microphone: the big screen, listening at once.
                    .onOpenURL { url in
                        guard url.host == "dictate" else { return }
                        let keyboard = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                            .first { $0.name == "context" }?.value
                            .flatMap { Data(base64Encoded: $0) }
                            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        DictationScreen.open(keyboard: keyboard)
                    }
            }
        }
    }
}

/// Settings and a way to try it by hand; day to day the app stays closed and the Action Button
/// drives it.
struct ContentView: View {
    @ObservedObject private var dictation = Dictation.shared
    @ObservedObject private var whisper = PhoneWhisper.shared
    @ObservedObject private var bench = EngineBench.shared
    @AppStorage("phoneOnly") private var phoneOnly = false
    @AppStorage(Server.addressKey) private var address = Server.defaultAddresses
    @AppStorage(Server.tokenKey) private var token = ""
    @State private var reachable: String??

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Addresses", text: $address, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $token)
                    Button("Paste Token") { token = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? token }
                    HStack {
                        Button("Check") { Task { reachable = await Server.reachable()?.address } }
                        Spacer()
                        if let reachable {
                            Text(reachable ?? "out of reach").font(.caption).foregroundStyle(reachable == nil ? .red : .green)
                        }
                    }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("One Mac per line, preferred first; its addresses comma-separated. A Mac that doesn't answer is passed over for \(Int(Server.downFor / 60)) minutes.")
                }
                Section("Try") {
                    Button(dictation.phase == .listening ? "Stop" : "Dictate") {
                        Task { _ = try? await dictation.toggle(waitingForScreenshot: false) }
                    }
                    .disabled(dictation.phase == .recognizing)
                    if dictation.phase == .listening { Text(dictation.preview.isEmpty ? "…" : dictation.preview).foregroundStyle(.secondary) }
                    if let last = dictation.last {
                        Text(last)
                        if let seconds = dictation.lastSeconds { Text(String(format: "%.2f s after release", seconds)).font(.caption).foregroundStyle(.secondary) }
                    }
                    if let problem = dictation.problem { Text(problem).foregroundStyle(.red) }
                    if whisper.enabled, let heard = whisper.last {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("On the phone").font(.caption).foregroundStyle(.secondary)
                            Text(heard.text.isEmpty ? "—" : heard.text)
                            Text(String(format: "%.2f s", heard.seconds)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    switch whisper.state {
                    case .absent:
                        Button("Download the Model (874 MB)") { whisper.fetchModel() }
                    case .downloading(let done):
                        ProgressView(value: done) { Text("Downloading the model…") }
                    case .loading:
                        HStack { ProgressView(); Text("Loading the model…") }
                    case .ready:
                        Toggle("Also hear on the phone", isOn: $whisper.enabled)
                        Toggle("Hear on the phone only (test)", isOn: $phoneOnly)
                        Text(PhoneWhisper.hasEncoder
                             ? whisper.aneLoadSeconds.map { String(format: "Neural Engine encoder loaded in %.1f s", $0) } ?? "Neural Engine encoder: loading…"
                             : "Neural Engine encoder: not on the phone").font(.caption).foregroundStyle(.secondary)
                        Button("Compare Engines") { bench.run(inBackground: false) }.disabled(bench.running)
                        Button("Compare in the Background") { bench.run(inBackground: true) }.disabled(bench.running)
                        ForEach(bench.lines, id: \.self) { Text($0).font(.caption) }
                    case .failed(let why):
                        Text(why).foregroundStyle(.red)
                        Button("Try Again") { whisper.fetchModel() }
                    }
                } header: {
                    Text("Whisper on the phone")
                } footer: {
                    Text("An experiment: a dictation made here, in the open app, is heard on the phone as well as on the Mac — the same model — to compare speed and text.")
                }
            }
            .navigationTitle("sweetch")
        }
        .fullScreenCover(isPresented: $dictation.screen) { DictationScreen() }
    }
}
