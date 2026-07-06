import Cocoa
import ApplicationServices

/// LLM-based autocorrection: fixes typos AND wrong-layout text ("ghbdtn" → "привет")
/// on the whole current keystroke buffer, using the focused field's text as context.
enum LLMCorrector {
    private static let systemPrompt = """
    You are a keyboard text-correction engine for a Punto-Switcher-style utility. The user just \
    typed text that is either (a) meaningful text in one language with maybe a few typos, or \
    (b) gibberish from typing with the WRONG keyboard layout — Russian typed on a US layout \
    ("ghbdtn" → "привет") or English typed on a Russian layout ("руддщ" → "hello").

    You are given RAW (what the user typed) and FLIPPED (RAW mapped deterministically through the \
    other keyboard layout). Do TWO things, in order:

    1. Pick the intended language: if RAW is already meaningful in its own script, keep RAW's \
       language; if RAW is layout gibberish, the intended text is FLIPPED.
    2. Return clean, correctly-spelled text in that language. FIX ALL TYPOS. The user's original \
       typos carry through the flip, so FLIPPED is often itself misspelled — you MUST correct it. \
       Every word in your output must be a real, correctly-spelled word in the target language. \
       Never output garbled or non-existent words.

    Preserve capitalization, punctuation and meaning. Return ONLY the final text — no quotes, no \
    explanation, no preamble. If the text is already fully correct, return it unchanged.

    Examples:
    RAW: ghbdtn
    FLIPPED: привет
    → привет

    RAW: fgddbkmysq dfhbfyn
    FLIPPED: апввильный вариант
    → правильный вариант

    RAW: helo wrold
    FLIPPED: рудщ цкщдв
    → hello world
    """

    /// Ask the model to correct `text`, giving it the deterministic layout-flip as a hint.
    /// `context` (surrounding field text) is reference-only.
    static func correct(text: String, context: String?) async -> String? {
        let flipped = LayoutTranslator.flip(text)
        log.info("LLM correct: flip hint '\(text, privacy: .public)' -> '\(flipped, privacy: .public)'")
        var user = """
        RAW: \(text)
        FLIPPED: \(flipped)
        """
        if let context, !context.isEmpty, context != text {
            user += "\n\nSurrounding field text (reference only, do NOT include it): \(String(context.prefix(1000)))"
        }
        user += "\n\n→ "
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
