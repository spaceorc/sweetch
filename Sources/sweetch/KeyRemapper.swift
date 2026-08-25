import Cocoa

struct KeyCombo: Equatable {
    var keyCode: Int64
    var flags: CGEventFlags
}

/// Karabiner-lite: turns one physical key into a different key combination.
///
/// The motivating case is a PC keyboard's context-menu key — macOS delivers it as a plain
/// keyDown (keycode 110) that nothing is bound to, so it's free real estate for a hotkey
/// like Shift+Ctrl+Opt+0.
///
/// Rules live in ~/Library/Application Support/sweetch/remaps.txt, one per line, and are
/// reloaded whenever the menu is opened:
///
///     menu = shift+ctrl+opt+0
///
/// The left side matches *exactly* — a bare `menu` fires only when no modifiers are held,
/// so it never shadows Shift+menu etc.
final class KeyRemapper {
    /// What a rule fires: another key combination, or one of sweetch's own actions.
    private enum Target {
        case combo(KeyCombo)
        case action(String)

        var description: String {
            switch self {
            case .combo(let c): return KeyNames.describe(keyCode: c.keyCode, flags: c.flags)
            case .action(let name): return "@\(name)"
            }
        }
    }

    private struct Rule {
        let from: KeyCombo
        let to: Target
    }

    /// Known action names, and what runs them. Set by the app at startup.
    var onAction: ((String) -> Void)?
    static let actions = ["screenshot"]

    private var rules: [Rule] = []
    private var loadedStamp: Date?
    /// Keys whose keyDown we swallowed: their keyUp has to be swallowed too, or the app
    /// sees a release for a press it never received.
    private var swallowed = Set<Int64>()

    init() { reload() }

    var isEmpty: Bool { rules.isEmpty }

    // MARK: - Event handling

    /// Called from the event tap for every real key event. Returns true if the event was
    /// consumed (the caller must swallow it).
    func handle(keyCode: Int64, flags: CGEventFlags, isDown: Bool) -> Bool {
        guard isDown else { return swallowed.remove(keyCode) != nil }
        guard let rule = rules.first(where: { $0.from.keyCode == keyCode && $0.from.flags == flags }) else {
            return false
        }
        swallowed.insert(keyCode)
        log.info("remap: \(KeyNames.describe(keyCode: rule.from.keyCode, flags: rule.from.flags), privacy: .public) -> \(rule.to.description, privacy: .public)")

        guard case .combo(let target) = rule.to else {
            if case .action(let name) = rule.to {
                DispatchQueue.main.async { [weak self] in self?.onAction?(name) }
            }
            return true
        }

        if rule.from.flags.isEmpty {
            // Fast path: no physical modifiers are down, so the synthetic combo can go out
            // immediately — right from the tap callback, keeping the remap feeling instant.
            Replayer.postKeyPair(keyCode: target.keyCode, flags: target.flags)
        } else {
            // The trigger itself used modifiers. Posting while they're still physically held
            // would let them bleed into the synthetic event, so wait for the release off the
            // tap thread (flagsState only updates once the callback has returned).
            DispatchQueue.global(qos: .userInteractive).async {
                Replayer.waitForModifierRelease(timeout: 0.3)
                Replayer.postKeyPair(keyCode: target.keyCode, flags: target.flags)
            }
        }
        return true
    }

    // MARK: - Config file

    func reload() {
        ensureFileExists()
        let text = (try? String(contentsOf: AppSupport.remaps, encoding: .utf8)) ?? ""
        rules = Self.parse(text)
        loadedStamp = modifiedAt()
        for rule in rules {
            log.info("remap rule: \(KeyNames.describe(keyCode: rule.from.keyCode, flags: rule.from.flags), privacy: .public) = \(rule.to.description, privacy: .public)")
        }
        if rules.isEmpty { log.info("remap: no rules") }
    }

    /// Cheap mtime check — called when the status menu opens, so edits take effect without
    /// an explicit reload or a restart.
    func reloadIfChanged() {
        let stamp = modifiedAt()
        guard stamp != loadedStamp else { return }
        reload()
    }

    private func modifiedAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppSupport.remaps.path)[.modificationDate]) as? Date
    }

    private func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: AppSupport.remaps.path) else { return }
        try? Self.defaultConfig.write(to: AppSupport.remaps, atomically: true, encoding: .utf8)
    }

    static let defaultConfig = """
    # sweetch key remaps — one rule per line:  <from> = <to>
    #
    # Keys:      letters a…z, digits 0…9, f1…f20, space, return, tab, escape, delete,
    #            forwarddelete, home, end, pageup, pagedown, left, right, up, down, menu,
    #            keypad0…keypad9 — or a raw virtual keycode: menu / key110 / 0x6e / 110.
    # Modifiers: cmd, shift, ctrl, opt — joined with '+'.
    # The right side can also be a sweetch action instead of a key: @screenshot — capture a
    # region and open it in the annotation editor.
    #
    # The left side matches exactly: `menu` fires only when no modifiers are held.
    # Windows keyboards: the context-menu key is `menu`; PrintScreen / ScrollLock / Pause
    # arrive as f13 / f14 / f15. Unsure what a key sends? Use "Detect Key…" in the menu.
    #
    # Edits are picked up the next time you open the sweetch menu.

    menu = shift+ctrl+opt+0
    f13 = @screenshot

    """

    // MARK: - Parsing

    private static func parse(_ text: String) -> [Rule] {
        var result: [Rule] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let sides = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard sides.count == 2, let from = combo(sides[0]), let to = target(sides[1]) else {
                log.error("remaps.txt line \(index + 1, privacy: .public): can't parse '\(line, privacy: .public)'")
                continue
            }
            result.append(Rule(from: from, to: to))
        }
        return result
    }

    /// Right-hand side: either "@screenshot" (one of our own actions) or a key combination.
    private static func target(_ spec: String) -> Target? {
        guard spec.hasPrefix("@") else { return combo(spec).map(Target.combo) }
        let name = String(spec.dropFirst()).lowercased()
        guard actions.contains(name) else {
            log.error("remaps.txt: unknown action '@\(name, privacy: .public)'")
            return nil
        }
        return .action(name)
    }

    /// "shift+ctrl+opt+0" -> combo. Last token is the key, everything before it a modifier.
    private static func combo(_ spec: String) -> KeyCombo? {
        let tokens = spec.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let keyToken = tokens.last, let keyCode = KeyNames.keyCode(for: keyToken) else { return nil }
        var flags: CGEventFlags = []
        for token in tokens.dropLast() {
            guard let f = KeyNames.flags(for: token) else { return nil }
            flags.insert(f)
        }
        return KeyCombo(keyCode: keyCode, flags: flags)
    }
}
