// Listen-only key watcher for `make trace`: prints every key event twice over —
//   HID  = what the keyboard physically sent (before sweetch's tap)
//   APP  = what is actually delivered onward to apps (after sweetch swallowed/synthesized)
// Synthetic events from sweetch are flagged SWEETCH via its eventSourceUserData marker.
// Timestamps are wall-clock so lines line up with sweetch's own log. Needs Input Monitoring
// for the terminal it runs in.
import Cocoa

setvbuf(stdout, nil, _IOLBF, 0)
let marker: Int64 = 0x73776565_74636800   // Replayer.syntheticEventMarker
let clock: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f }()

func flagsString(_ f: CGEventFlags) -> String {
    var s = ""
    if f.contains(.maskControl)   { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift)     { s += "⇧" }
    if f.contains(.maskCommand)   { s += "⌘" }
    if f.contains(.maskSecondaryFn) { s += "fn" }
    return s.isEmpty ? "-" : s
}

func chars(_ e: CGEvent) -> String {
    var len = 0
    var buf = [UniChar](repeating: 0, count: 8)
    e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
    let s = String(utf16CodeUnits: buf, count: len)
    return s.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7f ? String(format: "\\x%02x", $0.value) : String($0) }.joined()
}

let callback: CGEventTapCallBack = { _, type, event, refcon in
    let tag = refcon.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? "?"
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        print("\(tag) tap disabled (\(type.rawValue))"); return Unmanaged.passUnretained(event)
    }
    let kind: String
    switch type {
    case .keyDown: kind = event.getIntegerValueField(.keyboardEventAutorepeat) != 0 ? "down(rep)" : "down"
    case .keyUp: kind = "up"
    case .flagsChanged: kind = "flags"
    default: kind = "t\(type.rawValue)"
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    let synth = event.getIntegerValueField(.eventSourceUserData) == marker ? " SWEETCH" : ""
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let t = clock.string(from: Date())
    print("\(t) \(tag) \(kind.padding(toLength: 9, withPad: " ", startingAt: 0)) key=\(code) '\(chars(event))' mods=\(flagsString(event.flags)) srcPid=\(pid)\(synth) front=\(front)")
    return Unmanaged.passUnretained(event)
}

let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
print("listen access: \(CGPreflightListenEventAccess())")
for (tap, place, tag) in [(CGEventTapLocation.cghidEventTap, CGEventTapPlacement.headInsertEventTap, "HID"),
                          (.cgAnnotatedSessionEventTap, .tailAppendEventTap, "APP")] {
    let ref = UnsafeMutableRawPointer(strdup(tag))
    guard let port = CGEvent.tapCreate(tap: tap, place: place, options: .listenOnly,
                                       eventsOfInterest: mask, callback: callback, userInfo: ref) else {
        print("\(tag): tapCreate failed — grant Input Monitoring to the terminal app"); exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    CGEvent.tapEnable(tap: port, enable: true)
}
print("watching… (HID = physical, APP = delivered)")
CFRunLoopRun()
