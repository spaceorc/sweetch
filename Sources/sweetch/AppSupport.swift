import Foundation

/// User-visible, user-editable data files under ~/Library/Application Support/sweetch/.
enum AppSupport {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("sweetch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var glossary: URL { dir.appendingPathComponent("glossary.txt") }
    static var persona: URL  { dir.appendingPathComponent("persona.txt") }
    static var history: URL  { dir.appendingPathComponent("history.jsonl") }
}
