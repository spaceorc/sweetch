import Cocoa
import ApplicationServices

/// LLM-based autocorrection: fixes typos AND wrong-layout text ("ghbdtn" → "привет")
/// on the whole current keystroke buffer, using the focused field's text as context.
enum LLMCorrector {
    private static let systemPrompt = """
    You are a keyboard text-correction engine for a Punto-Switcher-style utility. \
    The user just typed some text that may contain (a) ordinary typos, or (b) text typed in the \
    wrong keyboard layout — e.g. Russian words typed on a US layout ("ghbdtn" → "привет") or \
    English typed on a Russian layout ("руддщ" → "hello"). Return the text the user actually intended. \
    Return ONLY the corrected text — no quotes, no explanations, no preamble, no trailing commentary. \
    Preserve capitalization, punctuation, spacing and the user's language. \
    If the text is already correct, return it unchanged.
    """

    /// Ask the model to correct `text`. `context` (surrounding field text) is reference-only.
    static func correct(text: String, context: String?) async -> String? {
        let user: String
        if let context, !context.isEmpty, context != text {
            let trimmed = String(context.prefix(2000))
            user = """
            Surrounding text in the field (reference only — DO NOT include it in your answer):
            \(trimmed)

            Text to correct (output only this, corrected):
            \(text)
            """
        } else {
            user = text
        }
        do {
            return try await LLMClient.complete(system: systemPrompt, user: user)
        } catch {
            log.error("LLM correct failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Whole text of the currently focused element via Accessibility, for context.
    /// Works in Cocoa and most Electron fields (kAXValue), returns nil otherwise.
    static func focusedFieldText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        let element = focused as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
