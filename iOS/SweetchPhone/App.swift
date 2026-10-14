import SwiftUI

@main
struct SweetchPhoneApp: App {
    init() {
        Trace.note("launched")
        _ = Dictation.shared   // answers the keyboard from the start
        LivePreview.prepare()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // sweetch://dictate — the keyboard's microphone key when the microphone is off: here
                // it can be turned on; the user goes back by the status bar's "◀ Telegram".
                .onOpenURL { url in
                    guard url.host == "dictate", Dictation.shared.phase != .listening else { return }
                    let back = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first { $0.name == "back" }?.value
                    Task {
                        _ = try? await Dictation.shared.toggle(waitingForScreenshot: false)
                        // Listening: back to the app the keyboard was in, when it can be opened.
                        if Dictation.shared.phase == .listening, let back, let scheme = HostApp.scheme(for: back),
                           let url = URL(string: scheme) {
                            Trace.note("back to \(back)")
                            await UIApplication.shared.open(url)
                        }
                    }
                }
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
    @AppStorage(Dictation.warmMinutesKey) private var warmMinutes = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
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
                }
                Section {
                    Picker("Keep the microphone on", selection: $warmMinutes) {
                        Text("Off").tag(0)
                        Text("2 min").tag(2)
                        Text("10 min").tag(10)
                        Text("1 hour").tag(60)
                    }
                } footer: {
                    Text("After a dictation, so the keyboard's microphone key starts the next one at once. Off: the key opens sweetch.")
                }
                Section("Try") {
                    Button(dictation.phase == .listening ? "Stop" : "Dictate") {
                        Task { _ = try? await dictation.toggle(waitingForScreenshot: false) }
                    }
                    .disabled(dictation.phase == .recognizing)
                    if dictation.phase == .warm {
                        Button("Turn the Microphone Off") { Task { await dictation.coolDown(showing: nil) } }
                    }
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
