import Cocoa
import Carbon

enum LayoutTranslator {
    enum Script { case latin, cyrillic, other }

    /// Char↔char maps between primary and secondary layouts. Built dynamically via
    /// UCKeyTranslate so that it works with whatever layouts are configured in
    /// InputSourceSwitcher, not just ABC/RussianWin.
    static func buildMaps() -> (primaryToSecondary: [Character: Character],
                                secondaryToPrimary: [Character: Character]) {
        guard let primary = findSource(ids: InputSourceSwitcher.primaryIDs),
              let secondary = findSource(ids: InputSourceSwitcher.secondaryIDs) else {
            log.error("buildMaps: missing primary or secondary input source")
            return ([:], [:])
        }
        let primaryMap = keyCodeToChar(source: primary)
        let secondaryMap = keyCodeToChar(source: secondary)

        var p2s: [Character: Character] = [:]
        var s2p: [Character: Character] = [:]
        for (key, pChar) in primaryMap {
            if let sChar = secondaryMap[key] {
                p2s[pChar] = sChar
                s2p[sChar] = pChar
            }
        }
        return (p2s, s2p)
    }

    static func dominantScript(_ s: String) -> Script {
        var latin = 0
        var cyrillic = 0
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:    latin += 1
            case 0x0410...0x044F, 0x0401, 0x0451:     cyrillic += 1
            default: break
            }
        }
        if latin == 0 && cyrillic == 0 { return .other }
        return latin >= cyrillic ? .latin : .cyrillic
    }

    /// Char -> (keyCode, shift) for the layout that matches one of `ids`. Used when we
    /// need to *type* a char in that layout (Electron apps don't update on AXSet, so we
    /// have to physically synthesize each keystroke).
    static func reverseKeyMap(forIDs ids: [String]) -> [Character: (keyCode: CGKeyCode, shift: Bool)] {
        guard let source = findSource(ids: ids) else { return [:] }
        let kcMap = keyCodeToChar(source: source)
        var result: [Character: (CGKeyCode, Bool)] = [:]
        for (key, c) in kcMap {
            if result[c] == nil {
                result[c] = (CGKeyCode(key & 0xFF), (key & 0x100) != 0)
            }
        }
        return result
    }

    private static func keyCodeToChar(source: TISInputSource) -> [Int: Character] {
        guard let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return [:]
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataPtr).takeUnretainedValue() as Data
        var result: [Int: Character] = [:]
        layoutData.withUnsafeBytes { rawBuffer in
            guard let layoutPtr = rawBuffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for keyCode in 0..<128 {
                for shift in [false, true] {
                    var deadKeyState: UInt32 = 0
                    var chars: [UniChar] = [0, 0, 0, 0]
                    var length = 0
                    let modifierKeyState: UInt32 = shift ? UInt32((shiftKey >> 8) & 0xFF) : 0
                    let err = UCKeyTranslate(
                        layoutPtr,
                        UInt16(keyCode),
                        UInt16(kUCKeyActionDisplay),
                        modifierKeyState,
                        UInt32(LMGetKbdType()),
                        UInt32(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        4,
                        &length,
                        &chars
                    )
                    guard err == noErr, length == 1 else { continue }
                    let string = String(utf16CodeUnits: chars, count: length)
                    guard let c = string.first, c.unicodeScalars.first?.value ?? 0 >= 0x20 else { continue }
                    let key = keyCode | (shift ? 0x100 : 0)
                    result[key] = c
                }
            }
        }
        return result
    }

    private static func findSource(ids: [String]) -> TISInputSource? {
        guard let cfList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return nil }
        guard let sources = cfList as? [TISInputSource] else { return nil }
        return sources.first { src in
            guard let ptr = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            return ids.contains(id)
        }
    }
}
