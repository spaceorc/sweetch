import Cocoa

/// The annotation window: canvas on top, tool strip below.
///
/// sweetch is an LSUIElement app with no Dock icon, so this is the one place it puts a real
/// window on screen. Two consequences handled here: we have to activate the app explicitly
/// to get keyboard focus, and we have to hand focus *back* when we're done — otherwise the
/// Cmd+V the user is about to press lands nowhere.
final class ScreenshotEditor: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let canvas: AnnotationCanvas
    private let session: EditSession
    private let previousApp: NSRunningApplication?

    /// Called when the window goes away, so the owner can drop its reference.
    var onClose: ((ScreenshotEditor) -> Void)?
    /// Called with a file the user picked via Open — the owner decides to open a new window.
    var onOpenFile: ((URL) -> Void)?

    private var modeButtons: [(button: NSButton, mode: AnnotationCanvas.Mode)] = []
    private var applyButton: NSButton!
    private var cancelButton: NSButton!
    private var undoButton: NSButton!
    private var redoButton: NSButton!

    init?(fileURL: URL, previousApp: NSRunningApplication?) {
        guard let image = Screenshots.loadPixelAccurate(fileURL) else {
            log.error("editor: can't load \(fileURL.lastPathComponent, privacy: .public)")
            return nil
        }
        self.session = EditSession(imageURL: fileURL)
        self.previousApp = previousApp
        self.canvas = AnnotationCanvas(session: session, image: image)

        let contentSize = Self.fittingContentSize(pixelSize: image.size)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = fileURL.lastPathComponent
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = buildContent()
        applyWindowBorder()
        window.center()

        canvas.onChange = { [weak self] in self?.refreshToolbar() }
        refreshToolbar()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)   // accessory app: focus has to be taken explicitly
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)
    }

    /// macOS separates a window from the desktop mostly with its shadow; the system border
    /// is a hairline that all but disappears in dark mode against a dark background. This
    /// draws an explicit one. Only the bottom corners are rounded — the top two sit under
    /// the title bar and are square — and the radius has to match the system's, or the curve
    /// won't follow the window edge.
    static let windowCornerRadius: CGFloat = 10

    private func applyWindowBorder() {
        guard let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.cornerRadius = Self.windowCornerRadius
        content.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        content.layer?.masksToBounds = true

        // A layer border would be painted over by the full-bleed canvas, so the outline is
        // its own view, added last and click-through.
        let border = WindowBorderView()
        border.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(border)
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            border.topAnchor.constraint(equalTo: content.topAnchor),
            border.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    // MARK: - Layout

    /// Point size that shows the image 1:1 on a Retina display, shrunk to fit the screen.
    private static func fittingContentSize(pixelSize: CGSize) -> CGSize {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        var size = CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
        if let visible = NSScreen.main?.visibleFrame {
            let fit = min(1, min(visible.width * 0.85 / size.width,
                                 (visible.height * 0.85 - toolbarHeight) / size.height))
            size = CGSize(width: size.width * fit, height: size.height * fit)
        }
        return CGSize(width: max(size.width, 360), height: max(size.height, 200) + toolbarHeight)
    }

    private static let toolbarHeight: CGFloat = 52

    private func buildContent() -> NSView {
        let content = EditorContentView()
        content.onKeyEquivalent = { [weak self] event in self?.handleKeyEquivalent(event) ?? false }
        content.onCancel = { [weak self] in self?.handleEscape() }
        content.onReturn = { [weak self] in self?.handleReturn() }
        content.onDelete = { [weak self] in self?.canvas.deleteSelection() }

        let toolbar = buildToolbar()
        for view in [canvas, toolbar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    private func buildToolbar() -> NSView {
        let bar = NSVisualEffectView()
        bar.material = .titlebar
        bar.blendingMode = .withinWindow
        bar.state = .active

        let copy = mainButton("COPY", tinted: true, action: #selector(copyAndClose))
        copy.toolTip = "Render to the clipboard and close (⏎ / ⌘C)"

        let arrow = mainButton("ARROW", tinted: false, action: #selector(pickArrow))
        arrow.toolTip = "Draw arrows; click one to move it or drag its ends"
        let crop = mainButton("CROP", tinted: false, action: #selector(pickCrop))
        crop.toolTip = "Drag out a crop frame — or click for a default one"
        modeButtons = [(arrow, .arrow), (crop, .crop)]

        applyButton = mainButton("APPLY", tinted: true, action: #selector(applyCrop))
        applyButton.toolTip = "Crop to the frame (⏎)"
        cancelButton = mainButton("CANCEL", tinted: false, action: #selector(cancelCrop))
        cancelButton.toolTip = "Discard the frame (esc)"

        undoButton = iconButton("arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        redoButton = iconButton("arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redo))
        let open = iconButton("folder", "Open an image… (⌘O)", #selector(openFile))

        let left = NSStackView(views: [copy, separator(), arrow, crop, applyButton, cancelButton])
        left.orientation = .horizontal
        left.spacing = 8

        let right = NSStackView(views: [undoButton, redoButton, separator(), open])
        right.orientation = .horizontal
        right.spacing = 6

        let row = NSStackView(views: [left, NSView(), right])
        row.orientation = .horizontal
        row.distribution = .fill
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        return bar
    }

    /// The big labelled buttons — the ones you actually aim at.
    private func mainButton(_ title: String, tinted: Bool, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 12, weight: .bold)
        if tinted { button.bezelColor = .controlAccentColor }
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func refreshToolbar() {
        for (button, mode) in modeButtons {
            let active = canvas.mode == mode
            button.bezelColor = active ? .controlAccentColor : nil
            button.contentTintColor = active ? .selectedMenuItemTextColor : nil
        }
        // APPLY/CANCEL only exist while there's a frame to act on — a stack view drops
        // hidden arranged views, so the row closes up on its own.
        applyButton.isHidden = !canvas.canApplyCrop
        cancelButton.isHidden = !canvas.canApplyCrop
        undoButton.isEnabled = canvas.canUndo
        redoButton.isEnabled = canvas.canRedo
    }

    // MARK: - Actions

    @objc private func pickArrow() { canvas.mode = .arrow }
    @objc private func pickCrop()  { canvas.mode = .crop }
    @objc private func undo()      { canvas.undo() }
    @objc private func redo()      { canvas.redo() }

    @objc private func applyCrop()  { canvas.applyCropFrame() }
    @objc private func cancelCrop() { canvas.cancelCropFrame() }

    /// Enter means "finish what I'm doing": apply the crop frame if one is drawn, otherwise
    /// the picture is done — copy it and get out of the way.
    private func handleReturn() {
        if canvas.canApplyCrop { applyCrop() } else { copyAndClose() }
    }

    /// Escape backs out one level: the frame first, the window only when there's no frame.
    private func handleEscape() {
        if canvas.canApplyCrop { cancelCrop() } else { window.performClose(nil) }
    }

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.directoryURL = Screenshots.dir
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.onOpenFile?(url)
        }
    }

    /// Flatten -> clipboard -> hand focus back. Only the clipboard ever sees baked pixels;
    /// the capture on disk stays untouched and the edits stay editable in the sidecar.
    @objc private func copyAndClose() {
        guard let png = canvas.flattenedPNG() else {
            log.error("editor: flatten failed")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)   // apps that only know the old type
        }
        session.save()
        log.info("editor: copied \(self.session.imageURL.lastPathComponent, privacy: .public)")
        window.close()
    }

    /// Matched on key *codes*, not characters: with a Cyrillic layout active
    /// `charactersIgnoringModifiers` hands back "я" for ⌘Z and "с" for ⌘C, so character
    /// matching quietly stops working in exactly the layout this app exists to switch to.
    private enum Key {
        static let c: UInt16 = 8
        static let z: UInt16 = 6
        static let o: UInt16 = 31
    }

    private func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        switch event.keyCode {
        case Key.c: copyAndClose(); return true
        case Key.z: if flags.contains(.shift) { redo() } else { undo() }; return true
        case Key.o: openFile(); return true
        default:    return false
        }
    }

    // MARK: - Offscreen render, for inspecting the chrome without a screen

    func debugRenderContent() -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    func debugForceCropFrame() {
        canvas.mode = .crop
        canvas.debugSetFrame()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        session.save()
        // Give focus back to whatever the user was in, so their paste goes to the right place.
        if let previousApp, !previousApp.isTerminated {
            if #available(macOS 14.0, *) {
                previousApp.activate()
            } else {
                previousApp.activate(options: [.activateIgnoringOtherApps])
            }
        }
        onClose?(self)
    }
}

/// The window's own outline: down both sides and across the bottom, with the bottom corners
/// rounded to match the system's. The top edge is left open — it meets the title bar.
private final class WindowBorderView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never swallow a click

    override func draw(_ dirtyRect: NSRect) {
        let radius = ScreenshotEditor.windowCornerRadius
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0.5, y: bounds.maxY))
        path.line(to: CGPoint(x: 0.5, y: radius + 0.5))
        path.appendArc(withCenter: CGPoint(x: radius + 0.5, y: radius + 0.5), radius: radius,
                       startAngle: 180, endAngle: 270)
        path.line(to: CGPoint(x: bounds.maxX - radius - 0.5, y: 0.5))
        path.appendArc(withCenter: CGPoint(x: bounds.maxX - radius - 0.5, y: radius + 0.5), radius: radius,
                       startAngle: 270, endAngle: 360)
        path.line(to: CGPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.65).setStroke()
        path.stroke()
    }
}

/// Content view that owns the window-level keyboard handling: Cmd-shortcuts arrive through
/// performKeyEquivalent, Escape through cancelOperation.
private final class EditorContentView: NSView {
    var onKeyEquivalent: ((NSEvent) -> Bool)?
    var onCancel: (() -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117:          // Backspace / Forward Delete: remove what's selected
            onDelete?()
        case 36, 76:           // Return / Numpad Enter
            onReturn?()
        default:
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyEquivalent?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
