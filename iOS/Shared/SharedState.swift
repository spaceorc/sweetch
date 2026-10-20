import Foundation

/// What the app and the keyboard know of each other, in their app group (the paid team's, since
/// 19 Oct 2026): the keyboard's incognito — so a dictation the Action Button starts while the
/// keyboard is incognito (by hand, or in a private tab) takes no screenshot and nothing leaves the
/// phone either; and what the phone heard by itself, for the keyboard to take when it's back —
/// with no Mac, and with the app perhaps already suspended.
enum SharedState {
    static let group = "group.com.spaceorc.sweetch"
    private static let defaults = UserDefaults(suiteName: group)

    /// The keyboard is incognito now: turned on by hand (stays until turned off), or in a private
    /// field (until the keyboard leaves it).
    static var keyboardIncognito: Bool {
        get { defaults?.bool(forKey: "keyboardIncognito") ?? false }
        set { defaults?.set(newValue, forKey: "keyboardIncognito") }
    }

    /// A dictation heard on the phone itself: its text, its folder, and when (in milliseconds, as
    /// the app's loopback server numbers what it publishes).
    static func publishHeard(_ text: String, id: String?, seq: Int) {
        defaults?.set(["text": text, "id": id ?? "", "seq": seq], forKey: "phoneHeard")
    }

    /// The dictation heard on the phone, taken — gone for anyone asking after.
    static func takeHeard() -> (text: String, id: String?, seq: Int)? {
        guard let heard = defaults?.dictionary(forKey: "phoneHeard"), let text = heard["text"] as? String,
              let seq = heard["seq"] as? Int else { return nil }
        defaults?.removeObject(forKey: "phoneHeard")
        let id = heard["id"] as? String
        return (text, id?.isEmpty == false ? id : nil, seq)
    }
}
