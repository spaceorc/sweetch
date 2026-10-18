import Foundation

/// What was typed or said, in the system log: only its length, unless tracing asks for the text
/// (the Mac: `logText`, set by `make trace`, never while private). macOS keeps the log for days
/// and hands it out with diagnostics — a dictation, or a word typed in a private window, mustn't
/// be in it.
enum LogText {
    nonisolated(unsafe) static var full = false
}

/// The text for a log line: itself when tracing, its length otherwise.
func shown(_ text: String?) -> String {
    guard let text else { return "nil" }
    return masked(text)
}

/// The same for anything printed (lists, dictionaries of text).
func shown(_ value: Any) -> String { masked(String(describing: value)) }

/// One body for both: calling `shown` from the `Any` overload with a String picks the `Any`
/// overload again — it recursed until the stack ran out (crash, 18 Oct 2026).
private func masked(_ text: String) -> String {
    LogText.full ? text : "‹\(text.count) chars›"
}
