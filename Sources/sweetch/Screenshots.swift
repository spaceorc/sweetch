import Cocoa

/// The screenshot library: everything sweetch captures lands in one folder so the menu can
/// offer it back later. Plain files in ~/Pictures/sweetch — visible in Finder, backed up,
/// and openable by anything else that reads PNGs.
enum Screenshots {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let d = base.appendingPathComponent("sweetch", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f
    }()

    static func newFileURL(now: Date = Date()) -> URL {
        dir.appendingPathComponent("Screenshot \(stampFormatter.string(from: now)).png")
    }

    /// Most recently modified first — that's the order the menu wants.
    static func recent(limit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return files
            .filter { ["png", "jpg", "jpeg", "tiff", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { modified($0) > modified($1) }
            .prefix(limit)
            .map { $0 }
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// Load an image with its coordinate space pinned to *pixels*. Screenshots off a Retina
    /// display carry 2x pixels behind a 1x point size; leaving that mismatch in place is how
    /// annotations end up drawn at half scale, so every consumer here works in pixels.
    static func loadPixelAccurate(_ url: URL) -> NSImage? {
        guard let rep = NSImageRep(contentsOf: url) else { return nil }
        let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        guard size.width > 0, size.height > 0 else { return nil }
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private static var thumbCache: [String: NSImage] = [:]

    /// Small preview for a menu item, annotations and crop included — the list should show
    /// what the clipboard would get, not the raw capture. Cached against both the image and
    /// its sidecar, since the menu rebuilds on every open.
    static func thumbnail(for url: URL, height: CGFloat = 18) -> NSImage? {
        let sidecar = EditSession.sidecarURL(for: url)
        let key = "\(url.path)|\(modified(url).timeIntervalSince1970)|\(modified(sidecar).timeIntervalSince1970)|\(height)"
        if let cached = thumbCache[key] { return cached }
        guard let image = loadPixelAccurate(url) else { return nil }
        let doc = EditSession.load(for: url)?.doc ?? EditDoc()
        guard let thumb = AnnotationRenderer.thumbnail(image: image, doc: doc, height: height) else { return nil }
        if thumbCache.count > 64 { thumbCache.removeAll() }
        thumbCache[key] = thumb
        return thumb
    }
}

enum ScreenCapture {
    /// Native interactive region capture (the same crosshair as Cmd+Shift+4), straight to
    /// `url`. Blocks until the user finishes or cancels — call it off the main thread.
    /// Returns false if they cancelled; nothing is written in that case.
    static func interactiveRegion(to url: URL) -> Bool {
        // -i interactive, -o no window shadow when grabbing a window, -x no shutter sound.
        run(["-i", "-o", "-x", url.path], to: url)
    }

    /// The whole screen the pointer is on, with no selection step.
    ///
    /// Captured as an explicit region rather than with a bare `screencapture file.png`:
    /// that form writes one file *per display* on a multi-monitor setup, which would leave
    /// us guessing at the filename.
    static func fullScreen(to url: URL) -> Bool {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
              let primary = NSScreen.screens.first else { return false }
        let frame = screen.frame
        // screencapture measures y down from the top of the primary display; AppKit measures
        // up from its bottom.
        let top = primary.frame.height - frame.maxY
        let region = "\(Int(frame.minX)),\(Int(top)),\(Int(frame.width)),\(Int(frame.height))"
        return run(["-x", "-R", region, url.path], to: url)
    }

    private static func run(_ arguments: [String], to url: URL) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = arguments
        do {
            try task.run()
        } catch {
            log.error("screencapture failed to launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
        task.waitUntilExit()
        // screencapture exits 0 even when the user cancels, so the file is the real signal.
        let captured = FileManager.default.fileExists(atPath: url.path)
        if !captured { log.info("screencapture: nothing captured (status \(task.terminationStatus, privacy: .public))") }
        return captured
    }
}
