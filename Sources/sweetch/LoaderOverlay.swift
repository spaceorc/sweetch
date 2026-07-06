import Cocoa

/// A centered, click-through HUD shown while an LLM request is in flight.
/// Uses a non-activating panel so it never steals focus from the text field the
/// user is typing in (critical — we must type the correction back into it).
/// All methods are called from the main thread (setThinking runs on main).
final class LoaderOverlay {
    private var panel: NSPanel?
    private var spinner: NSProgressIndicator?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        spinner?.startAnimation(nil)
        panel.alphaValue = 0
        panel.orderFrontRegardless()          // show WITHOUT activating our app
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.spinner?.stopAnimation(nil)
        })
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

        // Keyboard glyph on top.
        if let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "sweetch") {
            let iv = NSImageView(image: img)
            iv.symbolConfiguration = .init(pointSize: 40, weight: .regular)
            iv.contentTintColor = .labelColor
            iv.frame = NSRect(x: (size.width - 56) / 2, y: 100, width: 56, height: 48)
            iv.imageScaling = .scaleProportionallyUpOrDown
            blur.addSubview(iv)
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
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 26, width: size.width, height: 18)
        blur.addSubview(label)

        panel.contentView = blur
        return panel
    }
}
