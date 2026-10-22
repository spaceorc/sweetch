import Foundation

/// The app's own events for the keyboard's log on the Mac (the phone hearing a dictation, the
/// Neural Engine's model loading…): put on the disk with the keyboard's (KeyLogSpool) and sent from
/// there — the keyboard's batches too, when the app reaches a Mac before the keyboard does.
enum PhoneLog {
    static func note(_ events: [[String: Any]]) async {
        guard KeyLogSpool.add(events) else {
            _ = await Server.reachable()?.keyboardLog(events, batch: UUID().uuidString)
            return
        }
        await flush()
    }

    /// What waits on the disk, to a Mac if one answers.
    static func flush() async {
        if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            KeyLogSpool.mirror(to: documents.appendingPathComponent("keylog-out"))
        }
        guard KeyLogSpool.waiting > 0, let mac = await Server.reachable() else { return }
        await KeyLogSpool.flush { events, batch in await mac.keyboardLog(events, batch: batch) }
    }
}
