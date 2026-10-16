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
    static var deliver: (([[String: Any]], String) async -> Bool)?

    private static var buffer: [[String: Any]] = []
    /// A batch no Mac took yet: sent again as it was, under the same id, so a Mac that did keep it
    /// (its answer lost on the way) drops the copy.
    private static var unsent: (id: String, events: [[String: Any]])?
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
                if !buffer.isEmpty || unsent != nil { note("flush-pending", ["left": buffer.count + (unsent?.events.count ?? 0)]) }
            }
        }
    }

    /// Sends what's gathered; what no Mac took stays for the next time.
    static func flush() async {
        guard let deliver, !sending else { return }
        sending = true
        defer { sending = false }
        while true {
            if unsent == nil {
                guard !buffer.isEmpty else { return }
                let events = Array(buffer.prefix(2000))
                buffer.removeFirst(events.count)
                unsent = (UUID().uuidString, events)
            }
            guard let batch = unsent, await deliver(batch.events, batch.id) else { return }
            unsent = nil
        }
    }
    private static var sending = false

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
        EventSpy.checkRecognizers()   // and those that move on a timer, between events
        guard last > 0 else { return }
        let gap = link.timestamp - last
        if gap > 0.1 { KeyLog.note("stall", ["ms": Int(gap * 1000)]) }
    }
}

/// Every event iOS hands the keyboard's process, before any view sees it: `UIWindow.sendEvent` is
/// where they all pass. A touch that reaches the process but never a key shows here and not in the
/// keys' own log; one that's missing here never reached the process at all.
@MainActor
enum EventSpy {
    private static var installed = false

    static func install() {
        guard !installed,
              let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
              let spying = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sweetch_sendEvent(_:)))
        else { return }
        method_exchangeImplementations(original, spying)
        installed = true
    }

    static func saw(_ event: UIEvent, in window: UIWindow) {
        guard event.type == .touches else {
            KeyLog.note("event", ["type": event.type.rawValue, "subtype": event.subtype.rawValue])
            return
        }
        for touch in event.allTouches ?? [] where touch.phase != .stationary {
            var fields = KeyLog.touch(touch, in: window)
            fields["phase"] = phase(touch.phase)
            fields["view"] = touch.view.map { String(describing: type(of: $0)) } ?? "none"
            fields["window"] = String(describing: type(of: window))
            fields["touches"] = event.allTouches?.count ?? 0
            if touch.phase == .began { (touch.gestureRecognizers ?? []).forEach(watch) }
            if touch.phase == .began || touch.phase == .ended || touch.phase == .cancelled {
                fields["recognizers"] = (touch.gestureRecognizers ?? []).map { recognizer in
                    "\(type(of: recognizer)):\(recognizer.state.rawValue)" + (recognizer.delaysTouchesBegan ? ":delays" : "")
                        + (recognizer.cancelsTouchesInView ? ":cancels" : "")
                }
            }
            KeyLog.note("raw", fields)
        }
    }

    /// Every recognizer met — those between the keys and the screen, and those on each touch —
    /// with the state it was last seen in.
    private final class Watched {
        weak var recognizer: UIGestureRecognizer?
        var state: UIGestureRecognizer.State
        let name: String
        let id: Int
        init(_ recognizer: UIGestureRecognizer) {
            self.recognizer = recognizer
            state = recognizer.state
            name = String(describing: type(of: recognizer))
            id = ObjectIdentifier(recognizer).hashValue & 0xFFFF
        }
    }
    private static var watched: [ObjectIdentifier: Watched] = [:]

    static func watch(_ recognizer: UIGestureRecognizer) {
        let key = ObjectIdentifier(recognizer)
        if watched[key] == nil { watched[key] = Watched(recognizer) }
    }

    /// After each event iOS hands the process: every recognizer whose state moved since — system
    /// recognizers change it without telling observers, so it's looked at, not listened for.
    static func checkRecognizers() {
        for (key, entry) in watched {
            guard let recognizer = entry.recognizer else {
                watched[key] = nil
                continue
            }
            let now = recognizer.state
            guard now != entry.state else { continue }
            var fields: [String: Any] = [
                "recognizer": entry.name, "id": entry.id,
                "on": recognizer.view.map { String(describing: type(of: $0)) } ?? "none",
                "from": state(entry.state), "to": state(now), "touches": recognizer.numberOfTouches,
            ]
            if recognizer.numberOfTouches > 0, let window = recognizer.view?.window {
                let point = recognizer.location(in: window)
                fields["x"] = KeyLog.round1(point.x)
                fields["y"] = KeyLog.round1(point.y)
            }
            entry.state = now
            KeyLog.note("gesture", fields)
        }
    }

    private static func state(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "\(state.rawValue)"
        }
    }

    /// The recognizers between the keys and the screen, as the keyboard comes up: any of them may
    /// hold a touch back or take it. Each is followed from then on (see `watch`).
    static func recognizers(from view: UIView) -> [String] {
        var found: [String] = []
        var current: UIView? = view
        var all = view.window?.gestureRecognizers ?? []
        while let holder = current {
            all += holder.gestureRecognizers ?? []
            for recognizer in holder.gestureRecognizers ?? [] {
                found.append("\(type(of: holder))/\(type(of: recognizer)) enabled:\(recognizer.isEnabled) delays:\(recognizer.delaysTouchesBegan) cancels:\(recognizer.cancelsTouchesInView)")
            }
            current = holder.superview
        }
        all.forEach(watch)
        return found
    }

    private static func phase(_ phase: UITouch.Phase) -> String {
        switch phase {
        case .began: "began"
        case .moved: "moved"
        case .stationary: "stationary"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .regionEntered: "region-entered"
        case .regionMoved: "region-moved"
        case .regionExited: "region-exited"
        @unknown default: "\(phase.rawValue)"
        }
    }
}

extension UIWindow {
    /// Swapped with `sendEvent(_:)` by EventSpy: this name calls the original.
    @objc func sweetch_sendEvent(_ event: UIEvent) {
        MainActor.assumeIsolated { EventSpy.saw(event, in: self) }
        sweetch_sendEvent(event)
        MainActor.assumeIsolated { EventSpy.checkRecognizers() }
    }
}
