import SwiftUI

@main
struct SweetchPhoneApp: App {
    init() {
        LivePreview.prepare()
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
            if ProcessInfo.processInfo.arguments.contains("--keyboard-preview") { KeyboardPreview() } else { ContentView() }
        }
    }
}

/// Settings and a way to try it by hand; day to day the app stays closed and the Action Button
/// drives it.
struct ContentView: View {
    @ObservedObject private var dictation = Dictation.shared
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
                }
            }
            .navigationTitle("sweetch")
        }
    }
}
