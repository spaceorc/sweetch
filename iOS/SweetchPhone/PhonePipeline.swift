import Foundation
import Security
import UIKit

/// The model's credentials on the phone: taken once from a Mac (its `/llm-config`, with the
/// server's token) and kept in the Keychain — never in the build. With them the phone can hear by
/// itself, the Mac's way, when no Mac answers.
enum Credentials {
    private static let service = "com.spaceorc.sweetch.phone"
    private static let account = "llm-env"
    private static let fetchedKey = "llmConfigFetched"

    /// What's kept, put where the pipeline reads it. At launch.
    static func load() {
        LLMClient.environment = keychain()
        if let name = UserDefaults.standard.string(forKey: "userName") { Prefix.userName = name }
    }

    /// Asked of a Mac now and then (daily): the credentials may have changed there.
    static func refresh(from mac: Server) async {
        let last = UserDefaults.standard.double(forKey: fetchedKey)
        guard keychain() == nil || Date().timeIntervalSince1970 - last > 24 * 3600,
              let (env, name) = try? await mac.llmConfig() else { return }
        store(env)
        UserDefaults.standard.set(name, forKey: "userName")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: fetchedKey)
        load()
    }

    private static func keychain() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var found: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func store(_ text: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = Data(text.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

/// The Mac's dictation pipeline (Sources/sweetch/Pipeline), run on the phone when no Mac answers:
/// the screen's text read from the screenshot, the prefix written from it, whisper's listenings
/// (whisper.cpp here), Apple's own hearing, the model settling them. Each dictation is kept in the
/// app's Documents/dictation, as the Mac keeps its own.
enum PhonePipeline {
    static var canHear: Bool { FileManager.default.fileExists(atPath: PhoneWhisper.modelFile.path) }

    static func newDirectory() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        let dir = URL.documentsDirectory.appendingPathComponent("dictation/\(formatter.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The context for the prefix, worked out while the user speaks: the screenshot's text, then the
    /// prefix. Blocks on the model — call off the main thread.
    static func context(screenshot: Data?, dir: URL) -> (Prefix?, ContextSnapshot.Gathered) {
        var ocr: String?
        if let screenshot {
            let png = dir.appendingPathComponent("window.png")
            try? screenshot.write(to: png)
            ocr = ContextSnapshot.readText(in: png)
        }
        let gathered = ContextSnapshot.Gathered(app: Prefix.unknownApp, windowTitle: nil, textBeforeCursor: nil,
                                                windowTexts: [], ocrText: ocr)
        return (Prefix.build(from: gathered), gathered)
    }

    /// Hears the recording the pipeline's way. `context` is the prefix being worked out; it's waited
    /// for a moment. Nil when nothing was heard or whisper isn't on the phone.
    static func hear(_ wav: URL, dir: URL, apple: String?,
                     context: Task<(Prefix?, ContextSnapshot.Gathered), Never>?) async -> Hearing.Settled? {
        let recording = dir.appendingPathComponent("recording.wav")
        try? FileManager.default.removeItem(at: recording)
        try? FileManager.default.copyItem(at: wav, to: recording)
        let started = Date()
        let settled: Hearing.Settled? = await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = { () -> (prefix: Prefix?, context: ContextSnapshot.Gathered?, apple: String?) in
                    let box = Box()
                    let ready = DispatchSemaphore(value: 0)
                    Task {
                        box.value = await context?.value
                        ready.signal()
                    }
                    _ = ready.wait(timeout: .now() + 1.5)
                    return (box.value?.0, box.value?.1, apple)
                }
                done.resume(returning: try? Hearing.hear(recording, dir: dir, prepared: prepared))
            }
        }
        var record: [String: Any] = ["device": "iPhone", "heard_on": "phone", "seconds": Date().timeIntervalSince(started)]
        if let apple { record["apple"] = apple }
        if let settled {
            record["text"] = settled.text
            record["versions"] = settled.versions.map(\.text)
            record["settlement"] = settled.settlement ?? NSNull()
        }
        try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted])
            .write(to: dir.appendingPathComponent("session.json"))
        return settled
    }

    private final class Box: @unchecked Sendable {
        var value: (Prefix?, ContextSnapshot.Gathered)?
    }
}
