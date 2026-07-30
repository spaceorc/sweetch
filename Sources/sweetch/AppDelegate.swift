import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var eventTap: EventTapManager?
    private let buffer = KeystrokeBuffer()
    private let loader = LoaderOverlay()
    private var converting = false
    private var llmCorrecting = false
    /// The last correction we applied (what we typed, and what was there before), for undo.
    /// Valid only until the user's next keystroke / click / window switch.
    private var lastCorrection: (typed: String, original: String)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        observeAppActivation()
        enableLoginItemIfNeeded()

        guard ensureAccessibilityPermission() else {
            log.error("Accessibility permission not granted. Grant it in System Settings and relaunch.")
            return
        }

        InputSourceSwitcher.dumpInstalled()
        _ = LLMClient.isConfigured   // touch the lazy config so the provider line lands in the log

        let switchHotkey  = Hotkey(keyCode: 49, flags: .maskCommand)                    // Cmd+Space
        let convertHotkey = Hotkey(keyCode: 49, flags: .maskAlternate)                  // Option+Space
        let llmHotkey     = Hotkey(keyCode: 49, flags: [.maskAlternate, .maskShift])    // Option+Shift+Space

        let manager = EventTapManager(
            bindings: [
                HotkeyBinding(hotkey: switchHotkey)  { [weak self] in self?.handleSwitch(); return true },
                HotkeyBinding(hotkey: convertHotkey) { [weak self] in self?.handleConvert(); return true },
                HotkeyBinding(hotkey: llmHotkey)     { [weak self] in self?.handleLLMCorrect(); return true },
            ],
            onKeyDown:   { [weak self] event in self?.handleKeyDown(event) },
            onMouseDown: { [weak self] in self?.buffer.clear(reason: "mouse click"); self?.lastCorrection = nil }
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

    private enum LLMTarget {
        case selection(String)      // correct the current AX selection
        case buffer(String)         // correct the whole keystroke buffer
    }

    private func handleLLMCorrect() {
        if llmCorrecting { return }

        // Second press with nothing typed since the last correction = undo it (and learn that
        // the user preferred their original wording — feeds the glossary).
        if let lc = lastCorrection {
            lastCorrection = nil
            Glossary.noteRevert(fromOriginal: lc.original, corrected: lc.typed)
            History.record(kind: "revert", original: lc.original, corrected: lc.typed,
                           app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
            performRevert(lc)
            return
        }

        guard LLMClient.isConfigured else {
            log.error("LLM correct: not configured (bundle sweetch.env missing or keyless)")
            return
        }

        let typedText = buffer.snapshot().map { $0.chars }.joined()
        let target: LLMTarget
        if let selection = SelectionConverter.currentSelection(typedText: typedText) {
            target = .selection(selection)
        } else if !typedText.isEmpty {
            target = .buffer(typedText)
        } else {
            log.info("LLM correct: nothing selected and buffer empty")
            return
        }

        let source: String = {
            switch target { case .selection(let s), .buffer(let s): return s }
        }()
        let context = LLMCorrector.focusedFieldText()

        llmCorrecting = true
        setThinking(true)
        log.info("LLM correct: requesting for '\(source, privacy: .public)'")

        Task { [weak self] in
            let corrected = await LLMCorrector.correct(text: source, context: context)

            await MainActor.run { [weak self] in
                guard let self else { return }
                defer { self.llmCorrecting = false; self.setThinking(false) }

                guard let corrected else { return }  // failure already logged
                guard corrected != source else {
                    log.info("LLM correct: already correct, no change")
                    return
                }

                switch target {
                case .selection:
                    // Confirm the selection is still what we corrected before clobbering it.
                    guard SelectionConverter.currentSelection(typedText: "") == source else {
                        log.info("LLM correct: selection changed during request, discarding")
                        return
                    }
                    log.info("LLM correct (selection): '\(source, privacy: .public)' -> '\(corrected, privacy: .public)'")
                    Replayer.waitForModifierRelease()
                    // One Backspace deletes the whole selection, then type the correction.
                    Replayer.replace(deleteCount: 1, with: corrected)
                    self.activateLayout(for: corrected)
                    self.lastCorrection = (typed: corrected, original: source)
                    History.record(kind: "correct", original: source, corrected: corrected,
                                   app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                    self.buffer.clear(reason: "after LLM selection correction")

                case .buffer:
                    // The user may have kept typing while we waited on the network.
                    let now = self.buffer.snapshot().map { $0.chars }.joined()
                    guard now == source else {
                        log.info("LLM correct: buffer changed during request, discarding")
                        return
                    }
                    log.info("LLM correct (buffer): '\(source, privacy: .public)' -> '\(corrected, privacy: .public)'")
                    Replayer.waitForModifierRelease()
                    Replayer.replace(deleteCount: source.count, with: corrected)
                    self.activateLayout(for: corrected)
                    self.lastCorrection = (typed: corrected, original: source)
                    History.record(kind: "correct", original: source, corrected: corrected,
                                   app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
                    self.buffer.clear(reason: "after LLM correction")
                }
            }
        }
    }

    /// Undo the last correction: delete what we typed, restore the original, revert layout.
    private func performRevert(_ lc: (typed: String, original: String)) {
        log.info("revert: '\(lc.typed, privacy: .public)' -> '\(lc.original, privacy: .public)'")
        // Off the tap thread: waitForModifierRelease needs live flagsState, and typing sleeps.
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            Replayer.waitForModifierRelease()
            Replayer.replace(deleteCount: lc.typed.count, with: lc.original)
            DispatchQueue.main.async {
                self?.activateLayout(for: lc.original)
                self?.buffer.clear(reason: "after revert")
            }
        }
    }

    /// After a correction, switch the active keyboard layout to match the corrected text's
    /// script — so the user's next keystrokes go in the right layout. Detected deterministically
    /// (no LLM needed); mixed text follows the majority; punctuation-only leaves layout as is.
    private func activateLayout(for text: String) {
        switch LayoutTranslator.dominantScript(text) {
        case .latin:    InputSourceSwitcher.select(byIDs: InputSourceSwitcher.primaryIDs)
        case .cyrillic: InputSourceSwitcher.select(byIDs: InputSourceSwitcher.secondaryIDs)
        case .other:    break
        }
    }

    /// Busy indicator while an LLM request is in flight: centered HUD overlay + menu-bar dim.
    private func setThinking(_ on: Bool) {
        if on { loader.show() } else { loader.hide() }
        guard let button = statusItem?.button else { return }
        let symbol = on ? "keyboard.badge.ellipsis" : "keyboard"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "sweetch") {
            img.isTemplate = true
            button.image = img
        }
        button.appearsDisabled = on
    }

    private func handleKeyDown(_ event: CGEvent) {
        // Any real keystroke ends the undo window (our own synthetic keys are filtered out
        // by the tap before reaching here).
        lastCorrection = nil
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
            self?.lastCorrection = nil
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
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(openDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Persona…", action: #selector(openPersona), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show History…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refine Dictionary from History", action: #selector(refineDictionary), keyEquivalent: ""))
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

    @objc private func openDictionary() {
        if !FileManager.default.fileExists(atPath: AppSupport.glossary.path) { Glossary.add([]) }
        NSWorkspace.shared.open(AppSupport.glossary)
    }

    @objc private func openPersona() {
        _ = Persona.text()   // creates the file with the default if missing
        NSWorkspace.shared.open(AppSupport.persona)
    }

    @objc private func showHistory() {
        let target = FileManager.default.fileExists(atPath: AppSupport.history.path) ? AppSupport.history : AppSupport.dir
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    @objc private func refineDictionary() {
        setThinking(true)
        Task { [weak self] in
            let added = await Distiller.run()
            await MainActor.run { [weak self] in
                self?.setThinking(false)
                log.info("distill: \(added, privacy: .public) new word(s) added")
                if added > 0 { NSWorkspace.shared.open(AppSupport.glossary) }  // show the result
            }
        }
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
