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

    init(bindings: [HotkeyBinding],
         onKeyDown: @escaping (CGEvent) -> Void,
         onMouseDown: @escaping () -> Void) {
        self.bindings = bindings
        self.onKeyDown = onKeyDown
        self.onMouseDown = onMouseDown
    }

    func start() throws {
        let mask = (1 << CGEventType.keyDown.rawValue)
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

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: selfPtr
        ) else {
            throw EventTapError.creationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
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
