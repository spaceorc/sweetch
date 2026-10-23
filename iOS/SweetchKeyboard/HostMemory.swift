import Foundation

/// What the keyboard has seen in each app, for a dictation's context: every field's text as it
/// was last pieced together, and what was dictated there — by the app's process, the only name
/// iOS gives a keyboard for an app. Kept across the keyboard's restarts, for the few apps used
/// last; the oldest go.
final class HostMemory {
    static let shared = HostMemory()

    struct Seen: Codable {
        var text: String
        var at: Date
    }

    struct Host: Codable {
        var fields: [Seen] = []
        var dictated: [Seen] = []
        var lastSeen = Date()
    }

    private let key = "hostMemory"
    /// Incognito: nothing seen is kept — from the start of a new process, by what was set by hand
    /// (the keyboard's own setting), before the keyboard comes up and says.
    var paused = UserDefaults.standard.bool(forKey: "incognito")
    private var hosts: [String: Host]

    private init() {
        hosts = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Host].self, from: $0) } ?? [:]
    }

    /// A field's text as now known. The same field grown or edited replaces its last record; another
    /// field (little in common with the last) is a new one.
    func saw(_ text: String, process: Int32?) {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4000))
        guard !paused, let process, text.count >= 3 else { return }
        var host = hosts[String(process)] ?? Host()
        if let last = host.fields.last, Self.sameField(last.text, text) {
            host.fields[host.fields.count - 1] = Seen(text: text, at: Date())
        } else {
            host.fields.append(Seen(text: text, at: Date()))
            if host.fields.count > 16 { host.fields.removeFirst(host.fields.count - 16) }
        }
        host.lastSeen = Date()
        hosts[String(process)] = host
        save()
    }

    func dictated(_ text: String, process: Int32?) {
        guard !paused, let process, !text.isEmpty else { return }
        var host = hosts[String(process)] ?? Host()
        host.dictated.append(Seen(text: String(text.prefix(2000)), at: Date()))
        if host.dictated.count > 10 { host.dictated.removeFirst(host.dictated.count - 10) }
        host.lastSeen = Date()
        hosts[String(process)] = host
        save()
    }

    func host(_ process: Int32?) -> Host? { process.flatMap { hosts[String($0)] } }

    /// Both texts begin alike (one typed on from the other, or edited at the end), or one holds the
    /// other.
    private static func sameField(_ a: String, _ b: String) -> Bool {
        let shorter = min(a.count, b.count)
        guard shorter > 0 else { return true }
        if a.contains(b) || b.contains(a) { return true }
        return a.commonPrefix(with: b).count >= min(40, shorter / 2)
    }

    private func save() {
        // A process of an app closed long ago is gone, and its number goes to another app in time.
        let old = Date().addingTimeInterval(-3 * 86_400)
        hosts = hosts.filter { $0.value.lastSeen > old }
        if hosts.count > 12 {
            hosts = Dictionary(uniqueKeysWithValues: hosts.sorted { $0.value.lastSeen > $1.value.lastSeen }.prefix(12).map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(hosts) { UserDefaults.standard.set(data, forKey: key) }
    }
}
