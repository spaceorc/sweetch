import ApplicationServices
import Carbon
import Cocoa

/// Whether what the user is doing now is private — checked the moment a key is pressed, before
/// anything is captured, in well under a millisecond: the user turned incognito on; an app that
/// handles secrets is in front (password managers, the login window, the user's own list in
/// privacy.txt); macOS has secure input on (a password field, a password manager, Terminal's
/// Secure Keyboard Entry); the focused field is a password field; or a browser window is private —
/// Safari's title ends ", Private Browsing", Chrome's "(Incognito)" (seen on this Mac, 18 Oct 2026),
/// the others' their own words.
///
/// Private means: no dictation (nothing recorded, captured or sent), no correction by the model
/// (it's in the cloud), nothing kept, and nothing of the text in the log.
enum Privacy {
    enum Reason: Equatable {
        case incognito
        case secureInput
        case passwordField
        case app(String)
        case browser(String)

        /// What the HUD says, short.
        var text: String {
            switch self {
            case .incognito: "incognito is on"
            case .secureInput: "secure input is on"
            case .passwordField: "password field"
            case .app(let name): name
            case .browser(let name): "\(name) private window"
            }
        }
    }

    private static let key = "incognito"

    /// Turned on by hand, from the menu: stays until turned off.
    static var incognito: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            refreshLogText()
        }
    }

    /// Apps that handle secrets: whatever is typed or shown there is never sweetch's.
    private static let apps: [String: String] = [
        "com.apple.Passwords": "Passwords",
        "com.apple.keychainaccess": "Keychain Access",
        "com.apple.SecurityAgent": "a system password prompt",
        "com.apple.LocalAuthentication.UIAgent": "a system password prompt",
        "com.apple.loginwindow": "the login window",
        "com.apple.ScreenSaver.Engine": "the screen saver",
        "com.keepersecurity.passwordmanager": "Keeper",
        "com.1password.1password": "1Password",
        "com.agilebits.onepassword7": "1Password",
        "com.bitwarden.desktop": "Bitwarden",
    ]

    /// Browsers, and how each marks a private window's title.
    private static let browsers: [String: (name: String, marker: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        let chromium = re(#"\((Incognito|Инкогнито|Private|InPrivate)\)\s*$"#)
        return [
            "com.apple.Safari": ("Safari", re(#"(Private Browsing|Частный доступ)\s*$"#)),
            "com.apple.SafariTechnologyPreview": ("Safari", re(#"(Private Browsing|Частный доступ)\s*$"#)),
            "com.google.Chrome": ("Chrome", chromium),
            "com.google.Chrome.canary": ("Chrome", chromium),
            "com.brave.Browser": ("Brave", chromium),
            "com.microsoft.edgemac": ("Edge", re(#"InPrivate"#)),
            "com.vivaldi.Vivaldi": ("Vivaldi", chromium),
            "com.operasoftware.Opera": ("Opera", re(#"(Private|Приватн)"#)),
            "company.thebrowser.Browser": ("Arc", re(#"(Incognito|Private)"#)),
            "org.mozilla.firefox": ("Firefox", re(#"Private Browsing\s*$"#)),
        ]
    }()

    /// The user's own: bundle ids, one per line, in Application Support/sweetch/privacy.txt.
    private static var ownApps: Set<String> {
        let url = AppSupport.dir.appendingPathComponent("privacy.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    /// Why `app` (in front, or about to be typed into) is private now — nil when it isn't.
    static func check(_ app: NSRunningApplication?) -> Reason? {
        let reason = find(app)
        lastPrivate = reason != nil
        refreshLogText()
        return reason
    }

    private static func find(_ app: NSRunningApplication?) -> Reason? {
        if incognito { return .incognito }
        let bundle = app?.bundleIdentifier ?? ""
        if let name = apps[bundle] { return .app(name) }
        if ownApps.contains(bundle) { return .app(app?.localizedName ?? bundle) }
        if IsSecureEventInputEnabled() { return .secureInput }
        // The focused field, and the browser's window title — AX, with a short timeout.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        if let field = AX.element(system, kAXFocusedUIElementAttribute),
           AX.string(field, kAXSubroleAttribute) == kAXSecureTextFieldSubrole as String {
            return .passwordField
        }
        if let app, let browser = browsers[bundle] {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.1)
            if let window = AX.element(ax, kAXFocusedWindowAttribute), let title = AX.string(window, kAXTitleAttribute),
               browser.marker.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) != nil {
                return .browser(browser.name)
            }
        }
        return nil
    }

    /// The last check found it private: until the next, nothing of the text goes to the log even
    /// when `logText` is on.
    private(set) static var lastPrivate = false

    /// Text in the log only for tracing (`make trace` sets `logText`), and never while private.
    static func refreshLogText() {
        LogText.full = UserDefaults.standard.bool(forKey: "logText") && !incognito && !lastPrivate
    }
}
