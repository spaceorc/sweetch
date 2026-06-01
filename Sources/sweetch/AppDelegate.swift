import Cocoa
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var eventTap: EventTapManager?
    private let buffer = KeystrokeBuffer()
    private var converting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        observeAppActivation()

        guard ensureAccessibilityPermission() else {
            log.error("Accessibility permission not granted. Grant it in System Settings and relaunch.")
            return
        }

        InputSourceSwitcher.dumpInstalled()

        let switchHotkey  = Hotkey(keyCode: 49, flags: .maskCommand)    // Cmd+Space
        let convertHotkey = Hotkey(keyCode: 49, flags: .maskAlternate)  // Option+Space

        let manager = EventTapManager(
            bindings: [
                HotkeyBinding(hotkey: switchHotkey)  { [weak self] in self?.handleSwitch() },
                HotkeyBinding(hotkey: convertHotkey) { [weak self] in self?.handleConvert() },
            ],
            onKeyDown:   { [weak self] event in self?.handleKeyDown(event) },
            onMouseDown: { [weak self] in self?.buffer.clear(reason: "mouse click") }
        )
        do {
            try manager.start()
            self.eventTap = manager
        } catch {
            log.error("failed to start event tap: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleSwitch() {
        InputSourceSwitcher.toggle()
        buffer.clear(reason: "manual layout toggle")
    }

    private func handleConvert() {
        if converting { return }
        converting = true

        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        log.info("convert hotkey received, frontmost=\(frontmost, privacy: .public)")

        // Dispatch to background so the event-tap callback returns immediately and
        // WindowServer can process the user's modifier-release events.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = SelectionConverter.tryConvert()

            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.converting = false }
                switch result {
                case .converted:
                    self.buffer.clear(reason: "after selection convert")
                case .noSelection:
                    Replayer.convertLastWord(buffer: self.buffer)
                }
            }
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Editing/navigation keys → buffer is out of sync with the document, drop it.
        switch keyCode {
        case 36, 76:                     // Return, Numpad Enter
            buffer.clear(reason: "Return")
            return
        case 53:                         // Escape
            buffer.clear(reason: "Escape")
            return
        case 48:                         // Tab
            buffer.clear(reason: "Tab")
            return
        case 51, 117:                    // Backspace, Forward Delete
            buffer.clear(reason: "Backspace/Delete")
            return
        case 123, 124, 125, 126:         // arrow keys
            buffer.clear(reason: "arrow keys")
            return
        default:
            break
        }

        // Anything with Cmd/Ctrl is a shortcut, not text input — drop buffer just in case.
        let flags = event.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            buffer.clear(reason: "shortcut keystroke")
            return
        }

        // Only collect keystrokes that produced printable text.
        var length = 0
        var chars: [UniChar] = [0, 0, 0, 0]
        event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
        guard length > 0 else { return }
        let string = String(utf16CodeUnits: chars, count: length)
        guard !string.isEmpty, string.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) else { return }

        let sourceID = InputSourceSwitcher.currentSourceID()
        buffer.append(Keystroke(
            keyCode: keyCode,
            flags: flags,
            chars: string,
            sourceID: sourceID,
            timestamp: Date()
        ))
    }

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.buffer.clear(reason: "app activation")
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "sweetch")
        image?.isTemplate = true
        item.button?.image = image
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit sweetch", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        self.statusItem = item
    }

    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
