import Foundation

/// Darwin notifications between the app and its keyboard: no payload, no App Group needed — the
/// free signing can't promise one. The keyboard asks the app to start or stop listening; the app
/// says whether its microphone is warm and when it starts and stops.
enum Signal: String, CaseIterable {
    /// Keyboard → app: start listening, or stop.
    case toggle
    /// Keyboard → app: is the microphone warm? Answered by `warm` or `listening`.
    case ping
    /// App → keyboard: the microphone is on, not recording; a toggle starts at once.
    case warm
    /// App → keyboard: recording.
    case listening
    /// App → keyboard: the microphone is off; a toggle won't be heard.
    case cold

    private var name: CFNotificationName { CFNotificationName("com.spaceorc.sweetch.\(rawValue)" as CFString) }

    func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), name, nil, nil, true)
    }

    /// `handler` runs on the main queue. Kept for the process's life.
    @MainActor func observe(_ handler: @escaping @MainActor () -> Void) {
        let first = Self.handlers[rawValue] == nil
        Self.handlers[rawValue, default: []].append(handler)
        guard first else { return }
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Self.observer, { _, _, name, _, _ in
            guard let raw = (name?.rawValue as String?)?.components(separatedBy: ".").last else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Signal.handlers[raw]?.forEach { $0() } }
            }
        }, name.rawValue, nil, .deliverImmediately)
    }

    /// The Darwin center wants an observer to file the registration under.
    private static let observer = UnsafeRawPointer(Unmanaged.passUnretained(Token.shared).toOpaque())
    private final class Token { static let shared = Token() }

    @MainActor private static var handlers: [String: [@MainActor () -> Void]] = [:]
}
