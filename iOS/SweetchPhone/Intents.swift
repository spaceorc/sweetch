import AppIntents

/// The Action Button's: the first press starts listening, the next stops it and returns what was
/// said, for the Shortcut to put on the clipboard (an app in the background can't). Runs in the background; the Live Activity is what shows — and being a
/// `LiveActivityIntent` is what lets it start one from there.
struct ToggleDictationIntent: AudioRecordingIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle Dictation"
    static let description = IntentDescription("Starts listening, or stops and copies what was said.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        Trace.note("intent: toggle")
        // Nil when it started — "no value" to the Shortcut, which an empty text is not.
        return .result(value: try await Dictation.shared.toggle())
    }
}

/// The Shortcut's second step: the screenshot it took, for the Mac to read the screen from.
struct AttachScreenshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Attach Screenshot to Dictation"
    static let openAppWhenRun = false

    @Parameter(title: "Screenshot", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
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
