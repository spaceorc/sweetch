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

        /// Everything known about where the user is speaking, for a model to read. The screen texts
        /// are cut at `screenLimit` characters each, and left out at 0.
        func described(screenLimit: Int, fieldLimit: Int = 2000) -> String {
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
            return parts.joined(separator: "\n\n")
        }
    }

}
