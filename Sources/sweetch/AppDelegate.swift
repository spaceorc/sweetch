import Cocoa
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var eventTap: EventTapManager?
    private let buffer = KeystrokeBuffer()
    private let remapper = KeyRemapper()
    private let loader = LoaderOverlay()
    private lazy var dictation = Dictation(overlay: loader)
    private static let dictationEnabledKey = "dictationEnabled"
    private static let serverEnabledKey = "dictationServerEnabled"
    private let server = DictationServer()
    private var converting = false
    private let autoLayout = AutoLayout()
    /// The last switch to the other layout made on its own, and when — ⌥Space right after takes it back.
    private var lastAutoLayout: (range: Range<Int>, at: Date)?
    private var llmCorrecting = false
    /// The last correction we applied (what we typed, and what was there before), for undo.
    /// Valid only until the user's next keystroke / click / window switch.
    private var lastCorrection: (typed: String, original: String)?
    /// "Detect Key…" is armed: the next key press is captured and reported instead of
    /// reaching the app underneath.
    private var detectingKey = false
    /// Open annotation windows, kept alive here — an accessory app has no document controller.
    private var editors: [ScreenshotEditor] = []
    private var dictationsWindow: DictationsWindow?
    private var capturing = false
    /// Summary of a crash the previous run died from, until the user opens it.
    private var pendingCrashReport: URL?
    private var crashItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Privacy.refreshLogText()   // the log carries text only while tracing
        Sweep.runIfNew()
        Quarantine.purge()
        watchPrivacy()
        // Newest instance wins. The watchdog hands over by starting a fresh copy, and this
        // is also what keeps a stray double-launch from leaving two event taps fighting.
        let handover = terminateOtherInstances()
        // During a handover the outgoing instance is alive and well, so there's nothing to
        // diagnose — only check for a crash when we're starting from nothing.
        if handover {
            CrashWatch.markLaunch()
        } else {
            CrashWatch.checkPreviousRun { [weak self] report in self?.noteCrashReport(report) }
        }

        setupMainMenu()
        setupStatusItem()
        observeAppActivation()
        enableLoginItemIfNeeded()

        guard ensureAccessibilityPermission() else {
            log.error("Accessibility permission not granted. Grant it in System Settings and relaunch.")
            return
        }

        remapper.onAction = { [weak self] name in self?.runAction(name) }
        InputSourceSwitcher.dumpInstalled()
        LayoutTranslator.prewarm()   // build the layout maps on the main thread, once
        _ = LLMClient.isConfigured   // touch the lazy config so the provider line lands in the log
        if isDictationEnabled {
            Whisper.warmUp()   // the model takes seconds to load; not on the first hold
            if #available(macOS 26.0, *) { LivePreview.prepare() }
        }
        if isServerEnabled { server.start() }

        let switchHotkey  = Hotkey(keyCode: 49, flags: .maskCommand)                    // Cmd+Space
        let convertHotkey = Hotkey(keyCode: 49, flags: .maskAlternate)                  // Option+Space
        let llmHotkey     = Hotkey(keyCode: 49, flags: [.maskAlternate, .maskShift])    // Option+Shift+Space

        let manager = EventTapManager(
            bindings: [
                HotkeyBinding(hotkey: switchHotkey)  { [weak self] in self?.handleSwitch(); return true },
                HotkeyBinding(hotkey: convertHotkey) { [weak self] in self?.handleConvert(); return true },
                HotkeyBinding(hotkey: llmHotkey)     { [weak self] in self?.handleLLMCorrect(); return true },
            ],
            holdToTalk: HoldToTalk(
                dictation: dictation,
                isDictationEnabled: { [weak self] in self?.isDictationEnabled ?? false },
                onTakeOver: { [weak self] in self?.buffer.clear(reason: "hold-to-talk"); self?.lastCorrection = nil }
            ),
            onRawKey:    { [weak self] keyCode, flags, isDown in
                self?.handleRawKey(keyCode: keyCode, flags: flags, isDown: isDown) ?? false
            },
            onKeyDown:   { [weak self] event in self?.handleKeyDown(event) },
            onPress:     { [weak self] event in self?.dictation.takeMark(event) ?? false },
            onMouseDown: { [weak self] in self?.buffer.clear(reason: "mouse click"); self?.lastCorrection = nil; self?.dictation.dropMark() }
        )
        do {
            try manager.start()
            self.eventTap = manager
        } catch {
            log.error("failed to start event tap: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    private func terminateOtherInstances() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != mine }
        for other in others {
            log.info("another instance is running (pid \(other.processIdentifier, privacy: .public)) — asking it to quit")
            other.terminate()
        }
        return !others.isEmpty
    }

    func applicationWillTerminate(_ notification: Notification) {
        TypingLog.shared.flushNow()
        Whisper.shutDown()
        CrashWatch.markCleanExit()
    }

    /// A crash report showed up for the previous run — say so where it can be seen.
    private func noteCrashReport(_ report: URL) {
        pendingCrashReport = report
        crashItem?.isHidden = false
        crashItem?.title = "⚠︎ Crashed last run — Show Report"
        refreshStatusIcon()
        log.error("crash report ready: \(report.path, privacy: .public)")
    }

    @objc private func showCrashReport() {
        guard let report = pendingCrashReport else {
            NSWorkspace.shared.activateFileViewerSelecting([CrashWatch.dir])
            return
        }
        NSWorkspace.shared.open(report)
        pendingCrashReport = nil     // seen; stop shouting about it
        crashItem?.isHidden = true
        refreshStatusIcon()
    }

    @objc private func toggleWatchdog() {
        if Watchdog.isInstalled {
            Watchdog.uninstall()
        } else {
            // Installing spawns a supervised copy, which will ask this one to quit.
            Watchdog.install()
        }
    }

    private func handleSwitch() {
        TypingLog.shared.note("switch")
        InputSourceSwitcher.toggle()
        buffer.clear(reason: "manual layout toggle")
    }

    private func handleConvert() {
        TypingLog.shared.note("convert")
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
                    self.convertTyped()
                }
            }
        }
    }

    /// ⌥Space with nothing selected. Right after a switch made on its own: taken back, and its
    /// words kept as typed from then on. Otherwise the last word goes to the other layout, with
    /// those of the same go before it that suit it no worse.
    private func convertTyped() {
        let keys = buffer.snapshot()
        if let last = lastAutoLayout, Date().timeIntervalSince(last.at) < 30, last.range.upperBound == keys.count {
            lastAutoLayout = nil
            autoLayout.keep(keys, range: last.range)
            TypingLog.shared.note("auto-layout-undone")
            Replayer.convert(range: last.range, buffer: buffer)
            return
        }
        lastAutoLayout = nil
        guard let range = autoLayout.range(in: keys, automatic: false) ?? buffer.lastWordRange() else {
            log.info("convert: buffer empty, nothing to convert")
            return
        }
        Replayer.convert(range: range, buffer: buffer)
    }

    private enum LLMTarget {
        case selection(String)      // correct the current AX selection
        case buffer(String)         // correct the whole keystroke buffer
    }

    private func handleLLMCorrect() {
        TypingLog.shared.note("correct")
        if llmCorrecting { return }
        // Private: the model is in the cloud — the layout is turned locally instead, as ⌥Space does.
        if let reason = Privacy.check(NSWorkspace.shared.frontmostApplication) {
            lastCorrection = nil
            loader.flash("private — no AI", detail: "\(reason.text) · layout turned on this Mac")
            log.info("LLM correct: private, converting locally")
            handleConvert()
            return
        }

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
        log.info("LLM correct: requesting for '\(shown(source), privacy: .public)'")

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
                    log.info("LLM correct (selection): '\(shown(source), privacy: .public)' -> '\(shown(corrected), privacy: .public)'")
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
                    log.info("LLM correct (buffer): '\(shown(source), privacy: .public)' -> '\(shown(corrected), privacy: .public)'")
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
        log.info("revert: '\(shown(lc.typed), privacy: .public)' -> '\(shown(lc.original), privacy: .public)'")
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
        if on, let img = NSImage(systemSymbolName: "keyboard.badge.ellipsis", accessibilityDescription: "Sweetch") {
            img.isTemplate = true
            button.image = img
        } else if !on {
            refreshStatusIcon()
        }
        button.appearsDisabled = on
    }

    private func runAction(_ name: String) {
        switch name {
        case "screenshot":      capture(.region, after: 0)
        case "screenshot-full": capture(.fullScreen, after: 0)
        default:                log.error("unknown action '\(name, privacy: .public)'")
        }
    }

    private enum CaptureMode {
        case region       // the native crosshair
        case fullScreen   // whole screen, no selection step
    }

    @objc private func captureScreenshot()  { capture(.region, after: 0) }
    /// From the menu, so the menu itself has time to come down before the shutter.
    @objc private func captureFullScreen()  { capture(.fullScreen, after: 0.25) }

    /// Capture into the screenshot library, then open the editor on the result.
    private func capture(_ mode: CaptureMode, after delay: TimeInterval) {
        if capturing { return }
        capturing = true
        // Whoever is frontmost right now is where the user wants to paste afterwards.
        let previousApp = NSWorkspace.shared.frontmostApplication
        let url = Screenshots.newFileURL()

        // screencapture blocks until the crosshair is done with — keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
            let captured: Bool
            switch mode {
            case .region:     captured = ScreenCapture.interactiveRegion(to: url)
            case .fullScreen: captured = ScreenCapture.fullScreen(to: url)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturing = false
                guard captured else { return }   // cancelled; nothing was written
                log.info("captured \(url.lastPathComponent, privacy: .public)")
                self.openEditor(for: url, previousApp: previousApp)
            }
        }
    }

    private func openEditor(for url: URL, previousApp: NSRunningApplication?) {
        guard let editor = ScreenshotEditor(fileURL: url, previousApp: previousApp) else { return }
        editor.onClose = { [weak self] closed in
            self?.editors.removeAll { $0 === closed }
            self?.updateActivationPolicy()
        }
        editor.onOpenFile = { [weak self] picked in
            // A new window rather than reusing this one: edits live only until Copy, and
            // silently discarding them because the user browsed to another file would sting.
            self?.openEditor(for: picked, previousApp: previousApp)
        }
        editors.append(editor)
        updateActivationPolicy()   // before show(), so the window opens into the right policy
        editor.show()
    }

    /// An accessory app has no Dock icon and no Cmd-Tab entry — right for a menu-bar
    /// utility, but it leaves an open editor window with no way back once it's buried. So
    /// sweetch is a regular app for exactly as long as a window is open, and slips back into
    /// the menu bar when the last one closes.
    private func updateActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = editors.isEmpty && dictationsWindow == nil ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    /// A minimal menu bar, for the stretches when we're a regular app. The Window menu is
    /// the real point: AppKit keeps the list of open editors in it automatically.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Hide Sweetch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Sweetch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem.separator())
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openRecentScreenshot(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openEditor(for: url, previousApp: NSWorkspace.shared.frontmostApplication)
    }

    @objc private func openScreenshotsFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([Screenshots.dir])
    }

    /// Rebuild the recents list each time the menu opens — cheap, and always current.
    private func refreshScreenshotsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let recent = Screenshots.recent(limit: 12)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No screenshots yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        for url in recent {
            let item = NSMenuItem(title: formatter.string(from: Screenshots.modified(url)),
                                  action: #selector(openRecentScreenshot(_:)), keyEquivalent: "")
            item.representedObject = url
            item.image = Screenshots.thumbnail(for: url)
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let folder = NSMenuItem(title: "Open Folder…", action: #selector(openScreenshotsFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
    }

    /// Runs for every real key event, down and up, ahead of our own hotkeys. Returns true
    /// to swallow the event: either "Detect Key…" grabbed it, or a remap rule fired.
    private func handleRawKey(keyCode: Int64, flags: CGEventFlags, isDown: Bool) -> Bool {
        if detectingKey {
            if isDown { reportDetectedKey(keyCode: keyCode, flags: flags) }
            return true   // swallow both halves of the press so it doesn't leak into the app
        }
        guard remapper.handle(keyCode: keyCode, flags: flags, isDown: isDown) else { return false }
        if isDown {
            // The synthetic combo is a shortcut for some other app — same reasoning as any
            // Cmd/Ctrl keystroke, the buffer no longer tracks the document.
            buffer.clear(reason: "remapped key")
            lastCorrection = nil
        }
        return true
    }

    /// Arm the key detector: the next key press is reported (and eaten) rather than typed.
    @objc private func detectKey() {
        guard !detectingKey else { return }
        detectingKey = true
        loader.show(caption: "press a key…", spinning: false)
    }

    private func reportDetectedKey(keyCode: Int64, flags: CGEventFlags) {
        detectingKey = false
        let spec = KeyNames.describe(keyCode: keyCode, flags: flags)
        log.info("detect key: \(spec, privacy: .public) (keyCode=\(keyCode, privacy: .public))")
        // Off the tap callback — an alert would otherwise run a modal loop inside it.
        DispatchQueue.main.async { [weak self] in
            self?.loader.hide()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = spec
            alert.informativeText = """
                Virtual keycode \(keyCode).

                Add a line like this to remaps.txt to rebind it:

                    \(spec) = shift+ctrl+opt+0
                """
            alert.addButton(withTitle: "Copy Rule")
            alert.addButton(withTitle: "Done")
            if alert.runModal() == .alertFirstButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(spec) = shift+ctrl+opt+0", forType: .string)
            }
        }
    }

    private func handleKeyDown(_ event: CGEvent) {
        // Typing into our own editor window isn't the user writing text somewhere — never
        // let it into the correction buffer.
        if !editors.isEmpty && NSApp.isActive { return }

        // Any real keystroke ends the undo window (our own synthetic keys are filtered out
        // by the tap before reaching here).
        lastCorrection = nil
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Editing/navigation keys → buffer is out of sync with the document, drop it.
        switch keyCode {
        case 36, 76:                     // Return, Numpad Enter
            buffer.clear(reason: "Return")
            // A plain Return sends a chat message: the last chance to see what a dictation became.
            if event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]).isEmpty { dictation.noteReturn() }
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
        // A plain space after a word typed in the wrong layout: the word, and those of the same go
        // that suit the other layout too, typed again in it.
        if keyCode == 49, flags.intersection([.maskShift, .maskAlternate]).isEmpty, !converting,
           Privacy.check(NSWorkspace.shared.frontmostApplication) == nil {
            let keys = buffer.snapshot()
            guard let range = autoLayout.range(in: keys, automatic: true) else { return }
            converting = true
            let words = autoLayout.words(in: Array(keys[range])).map { "\($0.own) → \($0.other)" }
            TypingLog.shared.note("auto-layout", ["words": words.count])
            log.info("auto layout: \(shown(words.joined(separator: ", ")), privacy: .public)")
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                guard let self else { return }
                Replayer.convert(range: range, buffer: self.buffer)
                DispatchQueue.main.async {
                    self.lastAutoLayout = (range, Date())
                    self.converting = false
                }
            }
        }
    }

    private func observeAppActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            self?.buffer.clear(reason: "app activation")
            self?.lastCorrection = nil
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                SelectionConverter.wakeAccessibility(of: app)
            }
        }
        // An Electron app takes ~10–15s after AX is first asked for before its focused element is
        // reliable, so ask early — at our start for everything running, and shortly after any
        // launch (asking at the instant of launch can be ignored, hence the second try) — and
        // the warm-up is over by the time the user gets to convert there.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            SelectionConverter.wakeAccessibility(of: app)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for delay in [1.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if !app.isTerminated { SelectionConverter.wakeAccessibility(of: app) }
                }
            }
        }
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item
        refreshStatusIcon()
        let menu = NSMenu()
        // Built up front and hidden: the report often lands a beat after launch.
        let crash = NSMenuItem(title: "⚠︎ Crashed last run — Show Report",
                               action: #selector(showCrashReport), keyEquivalent: "")
        crash.isHidden = true
        menu.addItem(crash)
        crashItem = crash
        let loginItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        let watchdogItem = NSMenuItem(title: "Restart on Crash", action: #selector(toggleWatchdog), keyEquivalent: "")
        watchdogItem.state = Watchdog.isInstalled ? .on : .off
        watchdogItem.toolTip = "Run under a launchd agent that starts Sweetch at login and brings it back if it dies"
        menu.addItem(watchdogItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Edit Dictionary…", action: #selector(openDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Edit Persona…", action: #selector(openPersona), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Show History…", action: #selector(showHistory), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Refine Dictionary from History", action: #selector(refineDictionary), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        let incognitoItem = NSMenuItem(title: "Incognito", action: #selector(toggleIncognito), keyEquivalent: "")
        incognitoItem.toolTip = "Nothing recorded, captured, sent to the AI or kept — dictation and AI correction off, layout switching on. Private browser windows and password fields are incognito by themselves."
        menu.addItem(incognitoItem)
        let forgetItem = NSMenuItem(title: "Forget Last Dictation", action: #selector(forgetLastDictation), keyEquivalent: "")
        forgetItem.toolTip = "Take the last dictation out of the history, here and on the Mac mini — kept aside on this Mac for 30 days, then gone"
        menu.addItem(forgetItem)
        let dictationItem = NSMenuItem(title: "Dictation (Hold Space)", action: #selector(toggleDictation), keyEquivalent: "")
        dictationItem.toolTip = "Hold Space in a text field to dictate; Claude desktop and Claude Code keep their own"
        menu.addItem(dictationItem)
        menu.addItem(NSMenuItem(title: "Dictations…", action: #selector(showDictations), keyEquivalent: ""))
        let serverItem = NSMenuItem(title: "Dictation Server for iPhone", action: #selector(toggleServer), keyEquivalent: "")
        serverItem.toolTip = "Hear the iPhone's dictations on this Mac, on port \(DictationServer.port.rawValue)"
        menu.addItem(serverItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "New Screenshot", action: #selector(captureScreenshot), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Capture Whole Screen", action: #selector(captureFullScreen), keyEquivalent: ""))
        let screenshots = NSMenuItem(title: "Screenshots", action: nil, keyEquivalent: "")
        screenshots.submenu = NSMenu()
        menu.addItem(screenshots)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Edit Key Remaps…", action: #selector(openRemaps), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Detect Key…", action: #selector(detectKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Sweetch", action: #selector(quit), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu
    }

    /// The menu bar is the only place a crash can be reported — there's no window to notice.
    private func refreshStatusIcon() {
        let symbol = pendingCrashReport != nil ? "exclamationmark.triangle" : privateNow != nil ? "eye.slash" : "keyboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sweetch")
        image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = privateNow.map { "Sweetch — private: \($0.text)" } ?? "Sweetch"
    }

    /// Why the window in front is private now, if it is — for the icon: an eye.slash while
    /// incognito is on, and while a private browser window or a password field is in front.
    private var privateNow: Privacy.Reason?

    /// Looks at what's in front on every app switch and once a second (a private window opened
    /// in the same browser is no app switch) — the same check as a key press, well under 1 ms.
    private func watchPrivacy() {
        let look = { [weak self] in
            guard let self else { return }
            let reason = Privacy.check(NSWorkspace.shared.frontmostApplication)
            TypingLog.shared.setPrivate(reason != nil)
            if reason != self.privateNow { self.privateNow = reason; self.refreshStatusIcon() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in look() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in look() }
        look()
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

    @objc private func openRemaps() {
        remapper.reload()   // creates the file with the default rules if it's missing
        NSWorkspace.shared.open(AppSupport.remaps)
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

    private var isDictationEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.dictationEnabledKey) as? Bool ?? true
    }

    @objc private func forgetLastDictation() {
        let fm = FileManager.default
        let last = ((try? fm.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .max { $0.lastPathComponent < $1.lastPathComponent }
        guard let last, Quarantine.take(last, why: "forgotten") else {
            loader.flash("nothing to forget", detail: "no dictation kept")
            return
        }
        lastCorrection = nil
        log.info("dictation: forgot \(last.lastPathComponent, privacy: .public)")
        loader.flash("forgotten", detail: "the last dictation — here and on the Mac mini", symbol: "eye.slash")
    }

    @objc private func toggleIncognito() {
        Privacy.incognito.toggle()
        if Privacy.incognito { lastCorrection = nil }
        privateNow = Privacy.check(NSWorkspace.shared.frontmostApplication)
        TypingLog.shared.setPrivate(privateNow != nil)
        refreshStatusIcon()
        log.info("incognito \(Privacy.incognito ? "on" : "off", privacy: .public)")
    }

    @objc private func toggleDictation() {
        UserDefaults.standard.set(!isDictationEnabled, forKey: Self.dictationEnabledKey)
        if isDictationEnabled { Whisper.warmUp() }
        log.info("dictation \(self.isDictationEnabled ? "enabled" : "disabled", privacy: .public)")
    }

    private var isServerEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.serverEnabledKey)
    }

    @objc private func toggleServer() {
        UserDefaults.standard.set(!isServerEnabled, forKey: Self.serverEnabledKey)
        if isServerEnabled { server.start() } else { server.stop() }
    }

    @objc private func showDictations() {
        if dictationsWindow == nil {
            let window = DictationsWindow()
            window.onClose = { [weak self] in
                self?.dictationsWindow = nil
                self?.updateActivationPolicy()
            }
            dictationsWindow = window
            updateActivationPolicy()   // before show(), so the window opens into the right policy
        }
        dictationsWindow?.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // Refresh the "Start at Login" checkmark when the menu opens, in case the user
    // changed it from System Settings.
    func menuWillOpen(_ menu: NSMenu) {
        remapper.reloadIfChanged()   // pick up edits to remaps.txt without a restart
        if let item = menu.items.first(where: { $0.action == #selector(toggleDictation) }) {
            item.state = isDictationEnabled ? .on : .off
        }
        if let item = menu.items.first(where: { $0.action == #selector(toggleIncognito) }) {
            item.state = Privacy.incognito ? .on : .off
        }
        if let item = menu.items.first(where: { $0.action == #selector(toggleServer) }) {
            item.state = isServerEnabled ? .on : .off
        }
        if let item = menu.items.first(where: { $0.action == #selector(toggleWatchdog) }) {
            item.state = Watchdog.isInstalled ? .on : .off
        }
        if let submenu = menu.items.first(where: { $0.title == "Screenshots" })?.submenu {
            refreshScreenshotsMenu(submenu)
        }
        guard let item = menu.items.first(where: { $0.action == #selector(toggleLoginItem) }) else { return }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}
