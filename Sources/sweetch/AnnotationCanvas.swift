import Cocoa

/// The interactive surface: shows the image with its annotations and lets them be drawn,
/// picked up and reshaped. Owns no state of its own beyond what's being dragged right now —
/// the document lives in the EditSession, which persists after every gesture.
final class AnnotationCanvas: NSView {
    enum Mode { case arrow, crop }

    private enum Drag {
        case newArrow(from: CGPoint, to: CGPoint)
        case moveArrow(id: UUID, last: CGPoint)
        case moveArrowEnd(id: UUID, movingTo: Bool)     // false = the tail is being dragged
        case newCrop(anchor: CGPoint)
        case moveCrop(last: CGPoint)
        case resizeCrop(edges: CropEdges)               // which sides follow the mouse
    }

    /// Sides of the crop frame being dragged: one for an edge, two for a corner.
    struct CropEdges: OptionSet {
        let rawValue: Int
        static let minX = CropEdges(rawValue: 1 << 0)
        static let maxX = CropEdges(rawValue: 1 << 1)
        static let minY = CropEdges(rawValue: 1 << 2)
        static let maxY = CropEdges(rawValue: 1 << 3)
    }

    let session: EditSession
    let image: NSImage
    var onChange: (() -> Void)?

    var mode: Mode = .arrow {
        didSet {
            selectedArrowID = nil
            needsDisplay = true
            onChange?()
        }
    }

    private(set) var selectedArrowID: UUID?
    private var drag: Drag?

    private var pixelSize: CGSize { image.size }
    private var strokeWidth: CGFloat { AnnotationRenderer.strokeWidth(pixelSize: pixelSize) }
    private var doc: EditDoc { session.doc }

    /// Handle hit radius and drawn size, in view points.
    private let handleRadius: CGFloat = 5.5

    init(session: EditSession, image: NSImage) {
        self.session = session
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - State the toolbar asks about

    var canUndo: Bool { session.canUndo }
    var canRedo: Bool { session.canRedo }
    /// A frame is drawn and we're in the mode where applying it makes sense.
    var canApplyCrop: Bool { mode == .crop && doc.cropFrame != nil }

    /// Apply the drawn frame: it becomes the crop and stops being a frame. A separate edit
    /// from drawing it, so the two undo separately.
    func applyCropFrame() {
        guard let frame = doc.cropFrame else { return }
        session.commit { $0.crop = frame; $0.cropFrame = nil }
        mode = .arrow          // show the result
        afterEdit()
    }

    /// Throw the frame away without touching the applied crop.
    func cancelCropFrame() {
        guard doc.cropFrame != nil else { return }
        session.commit { $0.cropFrame = nil }
        afterEdit()
    }

    /// Click with no drag in crop mode: start from a sensible frame instead of nothing.
    private func defaultCropFrame() -> CGRect {
        let full = CGRect(origin: .zero, size: pixelSize)
        return full.insetBy(dx: full.width * 0.2, dy: full.height * 0.2)
    }

    func undo() { session.undo(); afterEdit() }
    func redo() { session.redo(); afterEdit() }

    /// Delete key: whatever is currently "selected" in this mode.
    func deleteSelection() {
        switch mode {
        case .arrow:
            guard let id = selectedArrowID else { return }
            session.commit { $0.arrows.removeAll { $0.id == id } }
            selectedArrowID = nil
        case .crop:
            if doc.cropFrame != nil {
                session.commit { $0.cropFrame = nil }
            } else if doc.crop != nil {
                session.commit { $0.crop = nil }
            }
        }
        afterEdit()
    }

    private func afterEdit() {
        needsDisplay = true
        onChange?()
    }

    // MARK: - Geometry

    /// What's on screen: the full image while framing a crop (you need to see what you're
    /// cutting away), the cropped region otherwise.
    private var displayRect: CGRect {
        mode == .crop ? CGRect(origin: .zero, size: pixelSize)
                      : AnnotationRenderer.canvasRect(pixelSize: pixelSize, doc: doc)
    }

    /// Where the image sits inside the view: aspect-fit and centred, so resizing the window
    /// — or a crop changing the aspect ratio — letterboxes instead of stretching.
    private var contentFrame: CGRect {
        let rect = displayRect
        // Inset so the picture never touches the window edge: the margin is what tells you
        // where the window ends when the shot happens to be of whatever is behind it.
        let bounds = self.bounds.insetBy(dx: 14, dy: 14)
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else { return self.bounds }
        let scale = min(bounds.width / rect.width, bounds.height / rect.height)
        let size = CGSize(width: rect.width * scale, height: rect.height * scale)
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func toPixels(_ viewPoint: CGPoint) -> CGPoint {
        let rect = displayRect, frame = contentFrame
        let scale = rect.width / max(frame.width, 1)
        let p = CGPoint(x: rect.minX + (viewPoint.x - frame.minX) * scale,
                        y: rect.minY + (viewPoint.y - frame.minY) * scale)
        return CGPoint(x: min(max(p.x, rect.minX), rect.maxX),
                       y: min(max(p.y, rect.minY), rect.maxY))
    }

    private func toView(_ pixelPoint: CGPoint) -> CGPoint {
        let rect = displayRect, frame = contentFrame
        let scale = frame.width / rect.width
        return CGPoint(x: frame.minX + (pixelPoint.x - rect.minX) * scale,
                       y: frame.minY + (pixelPoint.y - rect.minY) * scale)
    }

    private func toView(_ pixelRect: CGRect) -> CGRect {
        let a = toView(pixelRect.origin)
        let b = toView(CGPoint(x: pixelRect.maxX, y: pixelRect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// Pixels per view point — for turning view-space tolerances into image-space ones.
    private var pixelsPerPoint: CGFloat { displayRect.width / max(contentFrame.width, 1) }

    private func clampToImage(_ rect: CGRect) -> CGRect {
        CGRect(origin: .zero, size: pixelSize).intersection(rect)
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = toPixels(convert(event.locationInWindow, from: nil))
        let grab = handleRadius * pixelsPerPoint * 1.6
        drag = (mode == .arrow) ? arrowDrag(at: point, grab: grab) : cropDrag(at: point, grab: grab)
        needsDisplay = true
        onChange?()
    }

    private func arrowDrag(at point: CGPoint, grab: CGFloat) -> Drag {
        // An already-selected arrow gets first refusal on its own endpoints, so its handles
        // stay grabbable even where another arrow crosses them.
        if let selected = doc.arrow(selectedArrowID) {
            if hypot(point.x - selected.to.x, point.y - selected.to.y) < grab {
                return .moveArrowEnd(id: selected.id, movingTo: true)
            }
            if hypot(point.x - selected.from.x, point.y - selected.from.y) < grab {
                return .moveArrowEnd(id: selected.id, movingTo: false)
            }
        }
        if let hit = doc.arrows.reversed().first(where: {
            AnnotationRenderer.distance(from: point, to: $0) < max(strokeWidth * 2.5, grab)
        }) {
            selectedArrowID = hit.id
            return .moveArrow(id: hit.id, last: point)
        }
        selectedArrowID = nil
        return .newArrow(from: point, to: point)
    }

    private func cropDrag(at point: CGPoint, grab: CGFloat) -> Drag {
        guard let frame = doc.cropFrame else { return .newCrop(anchor: point) }

        // Corners win over edges, edges over the body — the usual precedence, so a corner
        // stays grabbable even though it also lies on two edges.
        var edges: CropEdges = []
        if abs(point.x - frame.minX) < grab { edges.insert(.minX) }
        if abs(point.x - frame.maxX) < grab { edges.insert(.maxX) }
        if abs(point.y - frame.minY) < grab { edges.insert(.minY) }
        if abs(point.y - frame.maxY) < grab { edges.insert(.maxY) }
        let withinY = point.y > frame.minY - grab && point.y < frame.maxY + grab
        let withinX = point.x > frame.minX - grab && point.x < frame.maxX + grab
        if !edges.isEmpty && withinX && withinY {
            return .resizeCrop(edges: edges)
        }
        if frame.contains(point) { return .moveCrop(last: point) }
        return .newCrop(anchor: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let current = drag else { return }
        let point = toPixels(convert(event.locationInWindow, from: nil))

        switch current {
        case .newArrow(let from, _):
            drag = .newArrow(from: from, to: point)

        case .moveArrow(let id, let last):
            let dx = point.x - last.x, dy = point.y - last.y
            session.updateLive { doc in
                guard let index = doc.arrows.firstIndex(where: { $0.id == id }) else { return }
                doc.arrows[index].from.x += dx; doc.arrows[index].from.y += dy
                doc.arrows[index].to.x += dx;   doc.arrows[index].to.y += dy
            }
            drag = .moveArrow(id: id, last: point)

        case .moveArrowEnd(let id, let movingTo):
            session.updateLive { doc in
                guard let index = doc.arrows.firstIndex(where: { $0.id == id }) else { return }
                if movingTo { doc.arrows[index].to = point } else { doc.arrows[index].from = point }
            }

        case .newCrop(let anchor):
            session.updateLive { $0.cropFrame = self.clampToImage(Self.rect(anchor, point)) }

        case .moveCrop(let last):
            let dx = point.x - last.x, dy = point.y - last.y
            session.updateLive { doc in
                guard var frame = doc.cropFrame else { return }
                frame.origin.x = min(max(frame.minX + dx, 0), self.pixelSize.width - frame.width)
                frame.origin.y = min(max(frame.minY + dy, 0), self.pixelSize.height - frame.height)
                doc.cropFrame = frame
            }
            drag = .moveCrop(last: point)

        case .resizeCrop(let edges):
            session.updateLive { doc in
                guard let frame = doc.cropFrame else { return }
                var minX = frame.minX, maxX = frame.maxX, minY = frame.minY, maxY = frame.maxY
                let minimum: CGFloat = 8    // clamp instead of letting a side cross its opposite
                if edges.contains(.minX) { minX = min(max(point.x, 0), maxX - minimum) }
                if edges.contains(.maxX) { maxX = max(min(point.x, self.pixelSize.width), minX + minimum) }
                if edges.contains(.minY) { minY = min(max(point.y, 0), maxY - minimum) }
                if edges.contains(.maxY) { maxY = max(min(point.y, self.pixelSize.height), minY + minimum) }
                doc.cropFrame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; afterEdit() }
        guard let current = drag else { return }

        switch current {
        case .newArrow(let from, let to):
            // A click that didn't travel is a misclick, not a one-pixel arrow.
            guard hypot(to.x - from.x, to.y - from.y) > strokeWidth * 2 else { return }
            let arrow = Arrow(from: from, to: to)
            session.commit { $0.arrows.append(arrow) }
            selectedArrowID = arrow.id

        case .newCrop:
            // A click that didn't travel isn't a zero-size frame — it means "give me one".
            // (Clicking outside an existing frame leaves it alone: nothing was dragged, so
            // there's no live edit to end.)
            if let drawn = doc.cropFrame, drawn.width >= 8, drawn.height >= 8 {
                session.endLiveEdit()
            } else {
                session.updateLive { $0.cropFrame = self.defaultCropFrame() }
                session.endLiveEdit()
            }

        case .resizeCrop:
            session.endLiveEdit()

        case .moveArrow, .moveArrowEnd, .moveCrop:
            session.endLiveEdit()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rect = displayRect
        let frame = contentFrame
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()
        drawImageGround(frame)
        image.draw(in: frame, from: rect, operation: .copy, fraction: 1.0)
        drawImageBorder(frame)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = frame.width / rect.width

        if mode == .crop { dimOutsideCrop(in: frame) }

        ctx.saveGState()
        // Read bottom-up: annotations are drawn in pixel space, shifted by what's in frame,
        // then scaled into place on screen.
        ctx.translateBy(x: frame.minX, y: frame.minY)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        AnnotationRenderer.drawArrows(doc, width: strokeWidth)
        if case .newArrow(let from, let to) = drag {
            NSColor.systemRed.setFill()
            AnnotationRenderer.arrowPath(from: from, to: to, width: strokeWidth).fill()
        }
        ctx.restoreGState()

        if mode == .crop, let cropFrame = doc.cropFrame {
            drawFrame(toView(cropFrame))
        }
        if mode == .arrow, let selected = doc.arrow(selectedArrowID) {
            drawHandle(at: toView(selected.from))
            drawHandle(at: toView(selected.to))
        }
    }

    /// A dark screenshot on a dark canvas has no visible edge — the picture just dissolves
    /// into the window. A cast shadow lifts it off the background; the hairline below draws
    /// the edge itself.
    private func drawImageGround(_ frame: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.black.setFill()      // the shadow needs something opaque to fall from
        frame.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawImageBorder(_ frame: CGRect) {
        let border = NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()   // adapts to light/dark
        border.stroke()
    }

    /// Everything outside the crop frame goes dim — you can still see it, which is the point
    /// of framing on the full image, but it reads as "not in the result".
    private func dimOutsideCrop(in frame: CGRect) {
        guard let crop = doc.cropFrame else { return }
        let hole = toView(crop).intersection(frame)
        let path = NSBezierPath(rect: frame)
        path.appendRect(hole)
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
    }

    private func drawFrame(_ rect: CGRect) {
        NSColor.black.withAlphaComponent(0.6).setStroke()
        let shadow = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        shadow.lineWidth = 1
        shadow.stroke()

        let path = NSBezierPath(rect: rect)
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.stroke()

        // Corners and edge midpoints — everything that can be grabbed gets a handle.
        for point in [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                      CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                      CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
                      CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)] {
            drawHandle(at: point)
        }
    }

    private func drawHandle(at point: CGPoint) {
        let rect = CGRect(x: point.x - handleRadius, y: point.y - handleRadius,
                          width: handleRadius * 2, height: handleRadius * 2)
        let circle = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    func debugSetFrame() {
        session.commit { $0.cropFrame = self.defaultCropFrame() }
        afterEdit()
    }

    // MARK: - Output

    func flattenedPNG() -> Data? {
        AnnotationRenderer.flattenedPNG(image: image, doc: doc)
    }
}
