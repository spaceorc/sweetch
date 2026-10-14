import ActivityKit

/// The Live Activity a dictation shows in the Dynamic Island and on the Lock Screen while it
/// listens and while the Mac hears it.
struct DictationActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case listening, recognizing, done, failed
            /// The microphone stays on between dictations, for the keyboard's key.
            case warm
        }
        var phase: Phase
        /// The live transcript while listening; the result once done; what went wrong.
        var text: String
    }
}
