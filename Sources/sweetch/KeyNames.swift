import Cocoa

/// Names ⇄ virtual keycodes, for the human-editable remap config and for "Detect Key…".
enum KeyNames {
    /// Canonical name -> virtual keycode (ANSI layout positions; these are physical, not
    /// affected by the active input source).
    static let canonical: [(String, Int64)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
        ("y", 16), ("t", 17), ("o", 31), ("u", 32), ("i", 34), ("p", 35), ("l", 37),
        ("j", 38), ("k", 40), ("n", 45), ("m", 46),
        ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("5", 23), ("6", 22),
        ("7", 26), ("8", 28), ("9", 25), ("0", 29),
        ("equal", 24), ("minus", 27), ("rightbracket", 30), ("leftbracket", 33),
        ("quote", 39), ("semicolon", 41), ("backslash", 42), ("comma", 43),
        ("slash", 44), ("period", 47), ("grave", 50),
        ("space", 49), ("return", 36), ("tab", 48), ("escape", 53), ("delete", 51),
        ("forwarddelete", 117), ("home", 115), ("end", 119), ("pageup", 116),
        ("pagedown", 121), ("left", 123), ("right", 124), ("down", 125), ("up", 126),
        ("menu", 110),
        ("f1", 122), ("f2", 120), ("f3", 99), ("f4", 118), ("f5", 96), ("f6", 97),
        ("f7", 98), ("f8", 100), ("f9", 101), ("f10", 109), ("f11", 103), ("f12", 111),
        ("f13", 105), ("f14", 107), ("f15", 113), ("f16", 106), ("f17", 64),
        ("f18", 79), ("f19", 80), ("f20", 90),
        ("keypad0", 82), ("keypad1", 83), ("keypad2", 84), ("keypad3", 85), ("keypad4", 86),
        ("keypad5", 87), ("keypad6", 88), ("keypad7", 89), ("keypad8", 91), ("keypad9", 92),
        ("keypadenter", 76), ("keypadplus", 69), ("keypadminus", 78), ("keypadmultiply", 67),
        ("keypaddivide", 75), ("keypaddecimal", 65), ("keypadequals", 81), ("keypadclear", 71),
    ]

    /// Spellings people actually type, mapped onto a canonical name above.
    private static let aliases: [String: String] = [
        "application": "menu", "contextmenu": "menu", "apps": "menu",
        "esc": "escape", "backspace": "delete", "del": "forwarddelete",
        "enter": "return", "ret": "return", "spacebar": "space",
        "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down",
        "pgup": "pageup", "pgdn": "pagedown",
        // Windows keyboards: these three keys arrive as F13/F14/F15 on macOS.
        "printscreen": "f13", "prtsc": "f13", "scrolllock": "f14", "pause": "f15",
    ]

    private static let byName: [String: Int64] = {
        var m = Dictionary(uniqueKeysWithValues: canonical)
        for (alias, target) in aliases { m[alias] = m[target] }
        return m
    }()

    private static let byCode: [Int64: String] = {
        var m: [Int64: String] = [:]
        for (name, code) in canonical where m[code] == nil { m[code] = name }
        return m
    }()

    /// "menu", "f13", "0" — or a raw keycode as "key110", "0x6e", "110".
    static func keyCode(for token: String) -> Int64? {
        let t = token.lowercased()
        if let code = byName[t] { return code }
        if t.hasPrefix("0x"), let v = Int64(t.dropFirst(2), radix: 16) { return v }
        if t.hasPrefix("key"), let v = Int64(t.dropFirst(3)) { return v }
        if let v = Int64(t) { return v }
        return nil
    }

    /// Canonical name if we know one, otherwise the raw-keycode spelling the parser accepts.
    static func name(for keyCode: Int64) -> String {
        byCode[keyCode] ?? "key\(keyCode)"
    }

    static func flags(for token: String) -> CGEventFlags? {
        switch token.lowercased() {
        case "cmd", "command", "meta", "win", "super", "⌘": return .maskCommand
        case "shift", "⇧":                                   return .maskShift
        case "ctrl", "control", "⌃":                         return .maskControl
        case "opt", "option", "alt", "⌥":                    return .maskAlternate
        default:                                             return nil
        }
    }

    /// Render a combo the way the config file spells it: "shift+ctrl+opt+0".
    static func describe(keyCode: Int64, flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskCommand)   { parts.append("cmd") }
        if flags.contains(.maskShift)     { parts.append("shift") }
        if flags.contains(.maskControl)   { parts.append("ctrl") }
        if flags.contains(.maskAlternate) { parts.append("opt") }
        parts.append(name(for: keyCode))
        return parts.joined(separator: "+")
    }
}
