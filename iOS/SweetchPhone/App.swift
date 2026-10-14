import SwiftUI

@main
struct SweetchPhoneApp: App {
    init() { LivePreview.prepare() }

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Settings and a way to try it by hand; day to day the app stays closed and the Action Button
/// drives it.
struct ContentView: View {
    @ObservedObject private var dictation = Dictation.shared
    @AppStorage(Server.addressKey) private var address = Server.defaultAddress
    @AppStorage(Server.tokenKey) private var token = ""
    @State private var reachable: Bool?

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    TextField("Address", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token", text: $token)
                    Button("Paste Token") { token = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? token }
                    HStack {
                        Button("Check") { Task { reachable = await Server.current.ping() } }
                        Spacer()
                        if let reachable {
                            Text(reachable ? "reachable" : "out of reach").foregroundStyle(reachable ? .green : .red)
                        }
                    }
                }
                Section("Try") {
                    Button(dictation.phase == .listening ? "Stop" : "Dictate") {
                        Task { _ = try? await dictation.toggle() }
                    }
                    .disabled(dictation.phase == .recognizing)
                    if dictation.phase != .idle { Text(dictation.preview.isEmpty ? "…" : dictation.preview).foregroundStyle(.secondary) }
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
