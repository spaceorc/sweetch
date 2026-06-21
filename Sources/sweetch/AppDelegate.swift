import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var eventTap: EventTapManager?
    private let buffer = KeystrokeBuffer()
    private var converting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        observeAppActivation()
        enableLoginItemIfNeeded()

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

        let typedText = buffer.snapshot().map { $0.chars }.joined()

        // Dispatch to background so the event-tap callback returns immediately and
        // WindowServer can process the user's modifier-release events.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let result = SelectionConverter.tryConvert(typedText: typedText)

            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.converting = false }
                switch result {
                case .converted:
                    self.buffer.clear(reason: "after selection convert")
                case .noSelection, .autocompleteDismissed:
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
        case 115, 116, 119, 121:         // Home, PageUp, End, PageDown
            buffer.clear(reason: "Home/End/Page keys")
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
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit sweetch", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
    }

    /// Register as a login item once, on first launch only, so the app survives a reboot.
    /// We must NOT re-register on every launch: that would override the user turning it off
    /// (from the menu or System Settings → General → Login Items).
    private func enableLoginItemIfNeeded() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status != .enabled {
                try service.register()
            }
            UserDefaults.standard.set(true, forKey: key)
            log.info("registered as login item (first launch)")
        } catch {
            log.error("login item register failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                log.info("unregistered login item")
            } else {
                try service.register()
                log.info("registered login item")
            }
        } catch {
            log.error("login item toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func ensureAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: CFDictionary = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Refresh the "Start at Login" checkmark when the menu opens, in case the user
    // changed it from System Settings.
    func menuWillOpen(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.action == #selector(toggleLoginItem) }) else { return }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
