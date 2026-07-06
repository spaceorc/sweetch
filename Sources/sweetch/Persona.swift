import Foundation

/// A user-editable description of who the user is, injected into the correction prompt so
/// the model treats domain jargon (dev slang, etc.) as intentional rather than "wrong".
enum Persona {
    static let defaultText = """
    The user is a software developer. English tech slang borrowed into Russian is normal and \
    INTENTIONAL for them — e.g. "заапрувил" (approved), "смёржил" (merged), "задеплоил" (deployed), \
    "закоммитил", "отревьюил", "пушнул", "релизнул", "запушил". Do NOT translate or normalize such \
    professional jargon into standard Russian synonyms; keep it exactly as the user wrote it. \
    They also freely mix English and Russian. Only fix genuine typos and wrong keyboard layout.
    """

    /// Current persona text (creates the file with the default on first access).
    static func text() -> String {
        if let s = try? String(contentsOf: AppSupport.persona, encoding: .utf8),
           !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s
        }
        try? defaultText.write(to: AppSupport.persona, atomically: true, encoding: .utf8)
        return defaultText
    }

    static func promptSection() -> String {
        "\n\nUSER PERSONA:\n" + text().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
