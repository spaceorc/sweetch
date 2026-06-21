import Cocoa

struct Hotkey {
    var keyCode: Int64
    var flags: CGEventFlags
}

struct HotkeyBinding {
    let hotkey: Hotkey
    let action: () -> Void
}

enum EventTapError: Error {
    case creationFailed
}

private let relevantFlagsMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

final class EventTapManager {
    private let bindings: [HotkeyBinding]
    private let onKeyDown: (CGEvent) -> Void
    private let onMouseDown: () -> Void
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Liveness watchdog. A tap can be "alive" by every API (tapIsEnabled / AXIsProcessTrusted
    // both true) yet receive no events — this happens when the app launches too early in the
    // login session (e.g. via a login item) before WindowServer is ready, leaving WindowServer
    // with a cached "no access" decision. We detect it by periodically posting a harmless null
    // event tagged with our marker and checking it comes back through the callback; if it
    // doesn't, the tap is dead and we recreate it.
    private var watchdog: Timer?
    private var probeAcked = true
    private var probeSource = CGEventSource(stateID: .privateState)

    init(bindings: [HotkeyBinding],
         onKeyDown: @escaping (CGEvent) -> Void,
         onMouseDown: @escaping () -> Void) {
        self.bindings = bindings
        self.onKeyDown = onKeyDown
        self.onMouseDown = onMouseDown
    }

    func start() throws {
        guard createTap() else { throw EventTapError.creationFailed }
        startWatchdog()
    }

    @discardableResult
    private func createTap() -> Bool {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        tap = nil
        runLoopSource = nil

        let mask = (1 << CGEventType.null.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.leftMouseDown.rawValue)
                 | (1 << CGEventType.rightMouseDown.rawValue)
                 | (1 << CGEventType.otherMouseDown.rawValue)
                 | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                 | (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<EventTapManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(type: type, event: event)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            log.error("event tap creation failed")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        self.tap = newTap
        self.runLoopSource = source
        log.info("event tap created; enabled=\(CGEvent.tapIsEnabled(tap: newTap), privacy: .public) trusted=\(AXIsProcessTrusted(), privacy: .public) listenAccess=\(CGPreflightListenEventAccess(), privacy: .public)")
        return true
    }

    private func startWatchdog() {
        watchdog?.invalidate()
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.healthCheck()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
        healthCheck()
    }

    private func healthCheck() {
        guard let tap else {
            createTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            log.info("watchdog: tap disabled, re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        // Liveness probe: post a tagged null event and see if it comes back.
        probeAcked = false
        if let probe = CGEvent(source: probeSource) {
            probe.setIntegerValueField(.eventSourceUserData, value: Replayer.syntheticEventMarker)
            probe.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.probeAcked else { return }
            log.error("watchdog: probe unacked — tap not delivering events, recreating")
            self.createTap()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Our own liveness probe coming back — the tap is alive. Swallow it (null events
        // are harmless either way).
        if type == .null {
            if event.getIntegerValueField(.eventSourceUserData) == Replayer.syntheticEventMarker {
                probeAcked = true
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        // Skip events we synthesized ourselves to avoid feedback loops
        // (e.g. our own Backspace clearing the buffer).
        if event.getIntegerValueField(.eventSourceUserData) == Replayer.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            onMouseDown()
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags.intersection(relevantFlagsMask)
            for binding in bindings {
                if keyCode == binding.hotkey.keyCode && flags == binding.hotkey.flags {
                    binding.action()
                    return nil
                }
            }
            onKeyDown(event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
