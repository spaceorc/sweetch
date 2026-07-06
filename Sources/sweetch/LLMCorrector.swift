import Cocoa
import ApplicationServices

/// LLM-based autocorrection: fixes typos AND wrong-layout text ("ghbdtn" → "привет")
/// on the whole current keystroke buffer, using the focused field's text as context.
enum LLMCorrector {
    private static let systemPrompt = """
    You are a keyboard text-correction engine for a Punto-Switcher-style utility. \
    The user just typed some text that is either (a) meaningful text with maybe a few typos, or \
    (b) gibberish produced by typing with the wrong keyboard layout — e.g. Russian typed on a US \
    layout ("ghbdtn" → "привет") or English typed on a Russian layout ("руддщ" → "hello").

    You are given the RAW text and its LAYOUT-FLIPPED version (the raw text mapped deterministically \
    through the other keyboard layout). Decide which one the user actually intended:
    - If RAW is already a meaningful word/phrase, return RAW (fixing obvious typos only).
    - If RAW is layout gibberish, return the LAYOUT-FLIPPED version (fixing obvious typos only).

    Return ONLY the final intended text — no quotes, no explanation, no preamble. \
    Preserve capitalization, punctuation and spacing.
    """

    /// Ask the model to correct `text`, giving it the deterministic layout-flip as a hint.
    /// `context` (surrounding field text) is reference-only.
    static func correct(text: String, context: String?) async -> String? {
        let flipped = LayoutTranslator.flip(text)
        log.info("LLM correct: flip hint '\(text, privacy: .public)' -> '\(flipped, privacy: .public)'")
        var user = """
        RAW (what the user typed): \(text)
        LAYOUT-FLIPPED (RAW mapped through the other keyboard layout): \(flipped)
        """
        if let context, !context.isEmpty, context != text {
            user += "\n\nSurrounding field text (reference only, do NOT include it): \(String(context.prefix(1000)))"
        }
        user += "\n\nReturn only the intended text."
        do {
            let result = try await LLMClient.complete(system: systemPrompt, user: user)
            // The model (and our trimming) drops edge spaces; re-attach the original's
            // leading/trailing spaces so a separating space isn't swallowed ("there?cool").
            return preservingEdgeSpaces(of: text, result)
        } catch {
            log.error("LLM correct failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Force the corrected text to keep the original's leading/trailing spaces
    /// (the buffer only ever contains the space char as whitespace).
    private static func preservingEdgeSpaces(of original: String, _ corrected: String) -> String {
        let lead = original.prefix { $0 == " " }
        let trail = original.reversed().prefix { $0 == " " }
        let core = corrected.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return String(lead) + core + String(repeating: " ", count: trail.count)
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
