import AppIntents

/// The Action Button's: the first press starts listening, the next stops it and puts what was said
/// on the clipboard. Runs in the background; the Live Activity is what shows — and being a
/// `LiveActivityIntent` is what lets it start one from there.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription("Starts listening, or stops and copies what was said.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        Trace.note("intent: toggle")
        return .result(value: try await Dictation.shared.toggle())
    }
}

/// The Shortcut's second step: the screenshot it took, for the Mac to read the screen from.
struct AttachScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Attach Screenshot to Dictation"
    static let openAppWhenRun = false

    @Parameter(title: "Screenshot", supportedContentTypes: [.image])
    var screenshot: IntentFile

    @MainActor
    func perform() async throws -> some IntentResult {
        Dictation.shared.attach(screenshot: screenshot.data)
        return .result()
    }
}

struct SweetchShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleDictationIntent(), phrases: ["Dictate with \(.applicationName)"],
                    shortTitle: "Dictate", systemImageName: "mic")
    }
}
