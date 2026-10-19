import Foundation

/// What the app and the keyboard know of each other, in their app group (the paid team's, since
/// 19 Oct 2026): the keyboard's incognito — so a dictation the Action Button starts while the
/// keyboard is incognito (by hand, or in a private tab) takes no screenshot and nothing leaves the
/// phone either.
enum SharedState {
    static let group = "group.com.spaceorc.sweetch"
    private static let defaults = UserDefaults(suiteName: group)

    /// The keyboard is incognito now: turned on by hand (stays until turned off), or in a private
    /// field (until the keyboard leaves it).
    static var keyboardIncognito: Bool {
        get { defaults?.bool(forKey: "keyboardIncognito") ?? false }
        set { defaults?.set(newValue, forKey: "keyboardIncognito") }
    }
}
