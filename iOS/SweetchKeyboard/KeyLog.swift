import UIKit

/// Everything that happens on the keyboard, for working out why typing on it isn't yet like typing
/// on iOS's own: every touch (where, how big, how late iOS delivered it, which key it went to, how
/// it ended), every action and what the field held after it, the main thread's stalls, and the
/// keyboard's own life. Kept in memory and sent to a Mac in batches; the Mac keeps it in
/// `keyboard/` beside the dictations, and the Macs sync it.
@MainActor
enum KeyLog {
    /// One run of the keyboard's process: a new one means iOS started it again.
    static let run = String(UUID().uuidString.prefix(8))
    /// Posts a batch to a Mac; false when none took it. Set by the model, which knows the Macs.
    static var deliver: (([[String: Any]]) async -> Bool)?

    private static var buffer: [[String: Any]] = []
    private static var flushing: Task<Void, Never>?
    private static let limit = 20_000

    static func note(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["e"] = event
        entry["t"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        entry["run"] = run
        buffer.append(entry)
        if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        if flushing == nil {
            flushing = Task {
                try? await Task.sleep(for: .seconds(3))
                await flush()
                flushing = nil
                if !buffer.isEmpty { note("flush-pending", ["left": buffer.count]) }
            }
        }
    }

    /// Sends what's gathered; what no Mac took stays for the next time.
    static func flush() async {
        guard !buffer.isEmpty, let deliver else { return }
        let batch = Array(buffer.prefix(2000))
        buffer.removeFirst(batch.count)
        if !(await deliver(batch)) {
            buffer.insert(contentsOf: batch, at: 0)
            if buffer.count > limit { buffer.removeLast(buffer.count - limit) }
        }
    }

    /// A touch as iOS gave it: where, how big and how firm, and how long iOS held it before
    /// delivering it (edge gestures and the like delay touches).
    static func touch(_ touch: UITouch, in view: UIView) -> [String: Any] {
        let point = touch.location(in: view)
        var fields: [String: Any] = [
            "touch": ObjectIdentifier(touch).hashValue & 0xFFFF,
            "x": round1(point.x), "y": round1(point.y),
            "radius": round1(touch.majorRadius), "tolerance": round1(touch.majorRadiusTolerance),
            "lag_ms": Int((ProcessInfo.processInfo.systemUptime - touch.timestamp) * 1000),
            "taps": touch.tapCount,
        ]
        if touch.maximumPossibleForce > 0 { fields["force"] = round1(touch.force / touch.maximumPossibleForce * 100) }
        return fields
    }

    /// A key: what it is, and where a point lies against it.
    static func key(_ key: KeySpec?, at point: CGPoint? = nil, prefix: String = "key") -> [String: Any] {
        guard let key else { return [prefix: "none"] }
        var fields: [String: Any] = [prefix: name(of: key.kind)]
        if let point {
            fields[prefix + "_dx"] = round1(point.x - key.frame.midX)
            fields[prefix + "_dy"] = round1(point.y - key.frame.midY)
            fields[prefix + "_inside"] = key.frame.contains(point)
        }
        return fields
    }

    static func name(of kind: KeySpec.Kind) -> String {
        switch kind {
        case .character(let character): character
        case .shift: "⇧"
        case .backspace: "⌫"
        case .more: "123"
        case .symbols: "#+="
        case .language: "lang"
        case .globe: "globe"
        case .space: "space"
        case .ret: "return"
        }
    }

    static func round1(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }
}

/// The main thread's stalls while the keyboard shows: a frame that came late means a touch or a
/// key's drawing waited.
@MainActor
final class StallWatch: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0

    func start() {
        stop()
        last = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        defer { last = link.timestamp }
        guard last > 0 else { return }
        let gap = link.timestamp - last
        if gap > 0.1 { KeyLog.note("stall", ["ms": Int(gap * 1000)]) }
    }
}
