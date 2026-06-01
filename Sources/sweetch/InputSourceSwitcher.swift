import Carbon
import Cocoa

enum InputSourceSwitcher {
    // Acceptable IDs for the two slots. Multiple IDs per slot tolerate naming variants
    // (e.g. US vs ABC for English). First installed match wins.
    static let primaryIDs:   [String] = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
    static let secondaryIDs: [String] = ["com.apple.keylayout.RussianWin"]

    static func select(byIDs ids: [String]) {
        let sources = installedKeyboardSources()
        guard let target = sources.first(where: { ids.contains(sourceID(of: $0)) }) else {
            log.error("select(byIDs): no installed layout matches \(ids, privacy: .public)")
            return
        }
        TISSelectInputSource(target)
    }

    static func toggle() {
        let sources = installedKeyboardSources()
        let currentID = currentSourceID()
        let targetIDs = primaryIDs.contains(currentID) ? secondaryIDs : primaryIDs
        guard let target = sources.first(where: { targetIDs.contains(sourceID(of: $0)) }) else {
            log.error("no installed layout matches \(targetIDs, privacy: .public); current=\(currentID, privacy: .public)")
            return
        }
        TISSelectInputSource(target)
    }

    static func dumpInstalled() {
        for src in installedKeyboardSources() {
            log.info("installed layout: \(sourceID(of: src), privacy: .public)")
        }
    }

    private static func installedKeyboardSources() -> [TISInputSource] {
        guard let cfList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() else { return [] }
        guard let sources = cfList as? [TISInputSource] else { return [] }
        return sources.filter { src in
            guard let categoryPtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceCategory) else { return false }
            let category = Unmanaged<CFString>.fromOpaque(categoryPtr).takeUnretainedValue()
            guard CFStringCompare(category, kTISCategoryKeyboardInputSource, []) == .compareEqualTo else { return false }
            guard let selectablePtr = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable) else { return false }
            let selectable = Unmanaged<CFBoolean>.fromOpaque(selectablePtr).takeUnretainedValue()
            return CFBooleanGetValue(selectable)
        }
    }

    static func currentSourceID() -> String {
        let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        return sourceID(of: current)
    }

    private static func sourceID(of source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}
