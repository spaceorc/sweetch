import Foundation

/// Secrets in text — keys and tokens by their known shapes (the gitleaks kind), a value after
/// "password:" or "token=", a card number that passes Luhn — masked to «secret:<kind>» before
/// anything is written to disk or sent to a model as context. On the device, regexes only.
///
/// Aggressive on purpose: the context is there for the names and terms the user will say, and
/// nobody says a 24-character token aloud, so a false alarm costs nothing and a miss is a leak.
/// Never for the text the user asked to correct — that goes back into their field.
enum Secrets {
    private struct Rule {
        let kind: String
        let re: NSRegularExpression
        /// The capture group that is the secret; 0 is the whole match.
        let group: Int
        var check: ((String) -> Bool)? = nil
    }

    private static let rules: [Rule] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            Rule(kind: "private-key", re: re(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#), group: 0),
            Rule(kind: "aws", re: re(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#), group: 0),
            Rule(kind: "github", re: re(#"\b(gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"#), group: 0),
            Rule(kind: "gitlab", re: re(#"\bglpat-[A-Za-z0-9_\-]{20,}"#), group: 0),
            Rule(kind: "slack", re: re(#"\bxox[abprs]-[A-Za-z0-9-]{10,}"#), group: 0),
            Rule(kind: "stripe", re: re(#"\b[sr]k_(live|test)_[A-Za-z0-9]{16,}"#), group: 0),
            Rule(kind: "api-key", re: re(#"\bsk-(ant-|proj-)?[A-Za-z0-9_\-]{20,}"#), group: 0),
            Rule(kind: "google", re: re(#"\bAIza[0-9A-Za-z_\-]{35}"#), group: 0),
            Rule(kind: "jwt", re: re(#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#), group: 0),
            Rule(kind: "url-password", re: re(#"[a-z][a-z0-9+.-]*://[^\s:/@]+:([^\s@/]+)@"#), group: 1),
            Rule(kind: "bearer", re: re(#"(?i)\bbearer\s+([A-Za-z0-9._~+/\-]{20,}=*)"#), group: 1),
            // A value said to be a secret: "password: …", "API_KEY=…", "пароль - …".
            Rule(kind: "password",
                 re: re(#"(?i)(?:password|passwd|pwd|passphrase|secret|token|api[_-]?key|access[_-]?key|пароль|токен)["']?[ \t]*(?:[:=]|=>|[ \t]-[ \t]|[ \t]is[ \t]|—)[ \t]*["']?([^\s"',;]{6,})"#),
                 group: 1, check: looksSet),
            // Card numbers: 4-4-4-4 (or 13–19 straight) with a real issuer's first digits and Luhn,
            // not part of a longer number or a decimal.
            Rule(kind: "card",
                 re: re(#"(?<![\d.,])(?:2[2-7]\d{2}|3[47]\d{2}|4\d{3}|5[1-5]\d{2}|6\d{3})(?:[ \-]?\d{4}){2}[ \-]?\d{1,7}(?![\d]|[.,]\d)"#),
                 group: 0, check: luhn),
        ]
    }()

    /// `text` with every secret in it masked, and the kinds found — nil when there are none.
    static func masked(_ text: String) -> (text: String, kinds: [String])? {
        guard text.count >= 6 else { return nil }
        var ranges: [(NSRange, String)] = []
        let ns = text as NSString
        for rule in rules {
            for m in rule.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range(at: rule.group)
                guard r.location != NSNotFound, r.length > 0 else { continue }
                if let check = rule.check, !check(ns.substring(with: r)) { continue }
                if ranges.contains(where: { NSIntersectionRange($0.0, r).length > 0 }) { continue }
                ranges.append((r, rule.kind))
            }
        }
        guard !ranges.isEmpty else { return nil }
        let out = NSMutableString(string: text)
        for (r, kind) in ranges.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: r, with: "«secret:\(kind)»")
        }
        return (out as String, ranges.map(\.1))
    }

    /// `text` with its secrets masked (itself when there are none).
    static func mask(_ text: String) -> String { masked(text)?.text ?? text }

    /// Every string in a JSON-like value masked; `kinds` collects what was found.
    static func mask(_ value: Any, kinds: inout [String]) -> Any {
        switch value {
        case let s as String:
            guard let m = masked(s) else { return s }
            kinds += m.kinds
            return m.text
        case let a as [Any]: return a.map { mask($0, kinds: &kinds) }
        case let d as [String: Any]: return d.mapValues { mask($0, kinds: &kinds) }
        default: return value
        }
    }

    /// A real value, not a placeholder, a mask or a word in a sentence about passwords.
    private static func looksSet(_ v: String) -> Bool {
        if v.hasPrefix("«") || v.hasPrefix("<") || v.hasPrefix("$") || v.hasPrefix("{") || v.hasPrefix("%") { return false }
        if Set(v).count <= 2 { return false }                      // ******, ••••••, xxxxxx
        if v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { return false }
        // Code, not a value: `token)`, `self.token()`, `settings.db.password`.
        if v.contains(where: { "()[]".contains($0) }) { return false }
        if v.range(of: #"^[a-z_][a-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil { return false }
        // A word ("password: required", "API key: Header", "токен истёк") isn't one; anything with
        // a digit, a capital inside, or a symbol is.
        let letters = v.filter(\.isLetter)
        let word = letters.count == v.count && v.dropFirst().allSatisfy(\.isLowercase)
        return !word
    }

    private static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count), Set(digits).count > 3 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            let x = i % 2 == 1 ? d * 2 : d
            sum += x > 9 ? x - 9 : x
        }
        return sum % 10 == 0
    }
}
