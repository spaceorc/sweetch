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
    2. Produce clean, correctly-spelled text in that language. FIX ALL TYPOS. The user's original \
       typos carry through the flip, so FLIPPED is often itself misspelled — you MUST correct it. \
       Every word must be a real, correctly-spelled word in the target language.

    Reply with ONE JSON object and NOTHING else (no code fences, no text around it):
    {"reasoning": "<terse tag, MAX 5 words>", "result": "<the corrected text>"}

    "reasoning" MUST be at most 5 words — a terse tag, never a sentence, no analysis, no \
    alternatives (e.g. "wrong-layout russian" or "already correct"). Do not think out loud; commit \
    directly. "result" must contain ONLY the final corrected text, roughly the same length as the \
    input, and nothing else. If the input is ambiguous or you are unsure, set "result" to the RAW \
    input unchanged rather than guessing.

    Examples:
    RAW: ghbdtn
    FLIPPED: привет
    {"reasoning": "latin gibberish → russian", "result": "привет"}

    RAW: fgddbkmysq dfhbfyn
    FLIPPED: апввильный вариант
    {"reasoning": "wrong-layout russian, fix typos", "result": "правильный вариант"}

    RAW: helo wrold
    FLIPPED: рудщ цкщдв
    {"reasoning": "english with typos", "result": "hello world"}

    RAW: сталда
    FLIPPED: cnfklf
    {"reasoning": "ambiguous, neither is clearly a word", "result": "сталда"}
    """

    private static let retryInstruction = """
    Your reply was not a single valid JSON object. Reply again with ONLY this, nothing else:
    {"reasoning": "...", "result": "..."}
    """

    /// Ask the model to correct `text`, giving it the deterministic layout-flip as a hint.
    /// Uses a JSON {reasoning, result} response so the model's commentary goes into `reasoning`
    /// and never into what we type. Retries once if the model doesn't return valid JSON.
    static func correct(text: String, context: String?) async -> String? {
        let flipped = LayoutTranslator.flip(text)
        log.info("LLM correct: flip hint '\(text, privacy: .public)' -> '\(flipped, privacy: .public)'")

        var firstUser = """
        RAW: \(text)
        FLIPPED: \(flipped)
        """
        if let context, !context.isEmpty, context != text {
            firstUser += "\n\nSurrounding field text (reference only, do NOT include it): \(String(context.prefix(1000)))"
        }

        var convo: [[String: String]] = [["role": "user", "content": firstUser]]

        for attempt in 0..<2 {
            let raw: String
            do {
                raw = try await LLMClient.complete(system: systemPrompt + Persona.promptSection() + Glossary.promptSection(), messages: convo)
            } catch {
                log.error("LLM correct failed: \(String(describing: error), privacy: .public)")
                return nil
            }

            if let result = parseResult(raw) {
                guard isPlausibleCorrection(result, of: text) else {
                    log.error("LLM correct: implausible result (len \(result.count, privacy: .public) vs \(text.count, privacy: .public)), discarding")
                    return nil
                }
                return preservingEdgeSpaces(of: text, result)
            }

            // Malformed JSON — mini chat: show the model its bad reply, ask once more.
            if attempt == 0 {
                log.info("LLM correct: non-JSON reply, retrying once")
                convo.append(["role": "assistant", "content": raw])
                convo.append(["role": "user", "content": retryInstruction])
            }
        }
        log.error("LLM correct: still not valid JSON after retry, discarding")
        return nil
    }

    /// Extract the "result" field from a JSON reply, tolerating surrounding text/code fences
    /// by taking the outermost { … }. Logs "reasoning" for debugging.
    private static func parseResult(_ raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? String else { return nil }
        if let reasoning = obj["reasoning"] as? String {
            log.info("LLM correct: reasoning='\(reasoning, privacy: .public)'")
        }
        return result
    }

    /// A real correction is about the same length as the input and doesn't invent newlines.
    /// Anything much longer, or newline-bearing when the input had none, is model commentary.
    private static func isPlausibleCorrection(_ result: String, of original: String) -> Bool {
        if result.contains("\n") && !original.contains("\n") { return false }
        return result.count <= original.count * 3 + 24
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
