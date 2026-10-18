import Cocoa

/// A centered, click-through HUD shown while an LLM request is in flight.
/// Uses a non-activating panel so it never steals focus from the text field the
/// user is typing in (critical — we must type the correction back into it).
/// All methods are called from the main thread (setThinking runs on main).
final class LoaderOverlay {
    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?
    private var caption: NSTextField?
    private var glyph: NSImageView?
    private var blur: NSVisualEffectView?
    private var detail: NSTextField?
    private var detailText = ""

    private static let squareSide: CGFloat = 176
    private static let wideWidth: CGFloat = 480
    private static let detailChars = 160

    /// `spinning: false` turns the HUD into a plain prompt (used by "Detect Key…"). Already on
    /// screen, it changes in place rather than fading in again.
    func show(caption text: String = "correcting…", spinning: Bool = true, symbol: String = "keyboard") {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        caption?.stringValue = text
        glyph?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sweetch")
        spinner?.isHidden = !spinning
        if spinning { spinner?.startAnimation(nil) } else { spinner?.stopAnimation(nil) }
        layout(panel)
        guard !(panel.isVisible && panel.alphaValue > 0) else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()          // show WITHOUT activating our app
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Text under the caption — dictation's words as they're heard. The HUD widens to hold it and
    /// keeps the end of a long one.
    func showDetail(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        detailText = trimmed.count > Self.detailChars ? "…" + trimmed.suffix(Self.detailChars) : trimmed
        guard let panel else { return }
        layout(panel)
    }

    /// A moment's notice — private: what isn't done, and why — then gone.
    func flash(_ text: String, detail: String, symbol: String = "eye.slash") {
        show(caption: text, spinning: false, symbol: symbol)
        showDetail(detail)
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.flashGeneration == generation else { return }
            self.hide()
        }
    }
    private var flashGeneration = 0

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.spinner?.stopAnimation(nil)
            self?.detailText = ""
        })
    }

    /// The square HUD, or a wider one with the detail text under it; centred either way.
    private func layout(_ panel: NSPanel) {
        let side = Self.squareSide
        var width = side
        var lift: CGFloat = 0
        detail?.stringValue = detailText
        detail?.isHidden = detailText.isEmpty
        if let detail, !detailText.isEmpty {
            width = Self.wideWidth
            let textWidth = width - 40
            let height = min(ceil(detail.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 400)).height ?? 20), 84)
            detail.frame = NSRect(x: 20, y: 18, width: textWidth, height: height)
            lift = height + 10
        }
        let size = NSSize(width: width, height: side + lift)
        panel.setContentSize(size)
        blur?.frame = NSRect(origin: .zero, size: size)
        glyph?.frame = NSRect(x: (width - 56) / 2, y: 100 + lift, width: 56, height: 48)
        spinner?.frame = NSRect(x: (width - 32) / 2, y: 56 + lift, width: 32, height: 32)
        caption?.frame = NSRect(x: 0, y: 26 + lift, width: width, height: 18)
        reposition(panel)
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let f = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - f.width / 2,
            y: screen.frame.midY - f.height / 2
        ))
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 176, height: 176)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver                    // above normal windows
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true               // click-through
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 28
        blur.layer?.masksToBounds = true
        self.blur = blur

        // Keyboard glyph on top.
        if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Sweetch") {
            let iv = NSImageView(image: img)
            iv.symbolConfiguration = .init(pointSize: 40, weight: .regular)
            iv.contentTintColor = .labelColor
            iv.frame = NSRect(x: (size.width - 56) / 2, y: 100, width: 56, height: 48)
            iv.imageScaling = .scaleProportionallyUpOrDown
            blur.addSubview(iv)
            self.glyph = iv
        }

        // Spinner in the middle.
        let spin = NSProgressIndicator(frame: NSRect(x: (size.width - 32) / 2, y: 56, width: 32, height: 32))
        spin.style = .spinning
        spin.isIndeterminate = true
        spin.controlSize = .regular
        blur.addSubview(spin)
        self.spinner = spin

        // Caption.
        let label = NSTextField(labelWithString: "correcting…")
        self.caption = label
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 26, width: size.width, height: 18)
        blur.addSubview(label)

        let words = NSTextField(wrappingLabelWithString: "")
        words.font = .systemFont(ofSize: 15)
        words.textColor = .labelColor
        words.alignment = .center
        words.maximumNumberOfLines = 4
        words.lineBreakMode = .byWordWrapping   // the start of a long text is cut in showDetail
        words.isHidden = true
        blur.addSubview(words)
        self.detail = words

        panel.contentView = blur
        return panel
    }
}
