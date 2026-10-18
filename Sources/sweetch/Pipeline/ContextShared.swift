import Foundation

/// What is known about where the user speaks — on the Mac gathered from the focused window
/// (ContextSnapshot.swift), on the iPhone from the screenshot and the keyboard's field.
enum ContextSnapshot {
    struct Gathered {
        let app: String
        let windowTitle: String?
        let textBeforeCursor: String?
        let windowTexts: [String]
        let ocrText: String?
        /// What the iPhone keyboard knew when its microphone opened the dictation (see `keyboard(_:)`).
        var keyboard: String? = nil

        /// Everything known about where the user is speaking, for a model to read. The screen texts
        /// are cut at `screenLimit` characters each, and left out at 0.
        func described(screenLimit: Int, fieldLimit: Int = 2000, keyboardLimit: Int = 6000) -> String {
            var parts = ["<app>\(app)</app>"]
            if let windowTitle { parts.append("<window_title>\(windowTitle)</window_title>") }
            // Not the persona either: its examples of the user's slang end up in every prefix as things
            // they "just did".
            // Not the glossary: it's the corrector's, learned from undos, and a stray word in it gets
            // worked into every prefix.
            if screenLimit > 0, !windowTexts.isEmpty {
                parts.append("<window_texts source=\"accessibility\">\n\(windowTexts.joined(separator: "\n").prefix(screenLimit))\n</window_texts>")
            }
            if screenLimit > 0, let ocrText, !ocrText.isEmpty {
                parts.append("<window_texts source=\"screenshot OCR\">\n\(ocrText.prefix(screenLimit))\n</window_texts>")
            }
            if let textBeforeCursor, !textBeforeCursor.isEmpty {
                parts.append("<field_before_cursor>\(textBeforeCursor.suffix(fieldLimit))</field_before_cursor>")
            }
            if keyboardLimit > 0, let keyboard, !keyboard.isEmpty {
                parts.append("<keyboard source=\"the user's iPhone keyboard in this app\">\n\(keyboard.suffix(keyboardLimit))\n</keyboard>")
            }
            // Nothing that looks like a key or a password goes to the model (Secrets.swift).
            return Secrets.mask(parts.joined(separator: "\n\n"))
        }
    }

    /// The iPhone keyboard's context (its `dictationContext`) as text for a model: the field after
    /// the cursor, what kind of field, the way of writing, the words typed lately, and what the
    /// keyboard saw in this app before — oldest first, so the latest is nearest the dictation.
    static func keyboard(_ k: [String: Any]) -> String {
        var lines: [String] = []
        if let after = k["field_after"] as? String, !after.isEmpty { lines.append("Field after the cursor: \(after)") }
        var kind: [String] = []
        let types = [1: "ASCII", 2: "numbers and punctuation", 3: "URL", 4: "number pad", 5: "phone pad",
                     7: "email", 8: "decimal pad", 9: "Twitter", 10: "web search", 11: "ASCII number pad"]
        if let type = k["keyboard_type"] as? Int, let name = types[type] { kind.append("\(name) keyboard") }
        if let content = k["content_type"] as? String, !content.isEmpty { kind.append("content: \(content)") }
        let returns = [1: "Go", 2: "Google", 3: "Join", 4: "Next", 5: "Route", 6: "Search", 7: "Send", 8: "Yahoo",
                       9: "Done", 10: "Emergency call", 11: "Continue"]
        if let type = k["return_type"] as? Int, let name = returns[type] { kind.append("return key: \(name)") }
        if !kind.isEmpty { lines.append("Field: \(kind.joined(separator: ", "))") }
        if let words = k["recent_words"] as? String, !words.isEmpty { lines.append("Words typed lately (any app): \(words)") }
        func listed(_ key: String, _ title: String) {
            guard let items = k[key] as? [[String: Any]], !items.isEmpty else { return }
            lines.append(title)
            for item in items {
                let ago = item["minutes_ago"] as? Int ?? 0
                let when = ago < 1 ? "just now" : ago < 120 ? "\(ago) min ago" : "\(ago / 60) h ago"
                lines.append("- \(when): \(item["text"] as? String ?? "")")
            }
        }
        listed("earlier_fields", "Earlier in this app — fields as the keyboard saw them, typed or not, oldest first:")
        listed("earlier_dictations", "Dictated earlier in this app, oldest first:")
        return lines.joined(separator: "\n")
    }

}
