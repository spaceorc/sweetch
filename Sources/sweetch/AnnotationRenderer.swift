import Cocoa

/// Draws an EditDoc over an image. Shared by the canvas, the flattener and the menu
/// thumbnails, so what you see, what you copy and what the menu shows can't drift apart.
enum AnnotationRenderer {
    /// The part of the original that's currently in frame.
    static func canvasRect(pixelSize: CGSize, doc: EditDoc) -> CGRect {
        let full = CGRect(origin: .zero, size: pixelSize)
        guard let crop = doc.crop else { return full }
        let clamped = crop.intersection(full)
        return (clamped.isNull || clamped.width < 1 || clamped.height < 1) ? full : clamped
    }

    /// Stroke weight scaled to the *original* image, not the crop — otherwise arrows would
    /// visibly swell and shrink while the crop frame is being dragged.
    static func strokeWidth(pixelSize: CGSize) -> CGFloat {
        max(3, min(pixelSize.width, pixelSize.height) / 160)
    }

    /// Draw the annotations in pixel space. The caller sets up the transform.
    static func drawAnnotations(_ doc: EditDoc, width: CGFloat) {
        NSColor.systemRed.setFill()
        for arrow in doc.arrows {
            arrowPath(from: arrow.from, to: arrow.to, width: width).fill()
        }
        NSColor.systemRed.setStroke()
        for stroke in doc.strokes {
            strokePath(stroke.points, width: width).stroke()
        }
    }

    /// A freehand stroke, smoothed: each recorded point becomes the control point of a
    /// quadratic running between the midpoints of its neighbours, which takes the jitter out
    /// of a mouse-drawn line without moving it anywhere the pointer didn't go.
    static func strokePath(_ points: [CGPoint], width: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        guard let first = points.first else { return path }
        guard points.count > 1 else {
            // A tap with no travel: draw the dot it looks like.
            return NSBezierPath(ovalIn: CGRect(x: first.x - width / 2, y: first.y - width / 2,
                                               width: width, height: width))
        }
        path.move(to: first)
        if points.count == 2 {
            path.line(to: points[1])
            return path
        }
        var start = first
        for index in 1..<(points.count - 1) {
            let control = points[index]
            let end = CGPoint(x: (control.x + points[index + 1].x) / 2,
                              y: (control.y + points[index + 1].y) / 2)
            // Quadratic expressed as a cubic: both controls sit two thirds of the way out.
            path.curve(to: end,
                       controlPoint1: CGPoint(x: start.x + 2.0 / 3 * (control.x - start.x),
                                              y: start.y + 2.0 / 3 * (control.y - start.y)),
                       controlPoint2: CGPoint(x: end.x + 2.0 / 3 * (control.x - end.x),
                                              y: end.y + 2.0 / 3 * (control.y - end.y)))
            start = end
        }
        path.line(to: points[points.count - 1])
        return path
    }

    /// A single filled polygon — shaft plus head. Filling one path rather than stroking a
    /// line and filling a triangle keeps the joint clean at any size.
    static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> NSBezierPath {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length          // along the arrow
        let px = -uy, py = ux                           // and across it

        let headLength = min(width * 4.5, length * 0.6)
        let headHalf = width * 2.2
        let shaftHalf = width / 2
        let neck = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)

        let path = NSBezierPath()
        path.move(to: CGPoint(x: from.x + px * shaftHalf, y: from.y + py * shaftHalf))
        path.line(to: CGPoint(x: neck.x + px * shaftHalf, y: neck.y + py * shaftHalf))
        path.line(to: CGPoint(x: neck.x + px * headHalf, y: neck.y + py * headHalf))
        path.line(to: to)
        path.line(to: CGPoint(x: neck.x - px * headHalf, y: neck.y - py * headHalf))
        path.line(to: CGPoint(x: neck.x - px * shaftHalf, y: neck.y - py * shaftHalf))
        path.line(to: CGPoint(x: from.x - px * shaftHalf, y: from.y - py * shaftHalf))
        path.close()
        return path
    }

    /// Distance from a point to the nearest part of a stroke.
    static func distance(from point: CGPoint, to stroke: Stroke) -> CGFloat {
        guard let first = stroke.points.first else { return .greatestFiniteMagnitude }
        var best = hypot(point.x - first.x, point.y - first.y)
        for index in 1..<max(stroke.points.count, 1) {
            best = min(best, distance(from: point, segment: stroke.points[index - 1], stroke.points[index]))
        }
        return best
    }

    /// Distance from a point to the arrow's shaft — hit testing for selection.
    static func distance(from point: CGPoint, to arrow: Arrow) -> CGFloat {
        distance(from: point, segment: arrow.from, arrow.to)
    }

    private static func distance(from point: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// Render crop + annotations at full original resolution. This is the only place pixels
    /// are ever baked — and it goes to the clipboard, never over the original file.
    static func flattenedPNG(image: NSImage, doc: EditDoc) -> Data? {
        let rect = canvasRect(pixelSize: image.size, doc: doc)
        let width = Int(rect.width.rounded()), height = Int(rect.height.rounded())
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: rect.size), from: rect, operation: .copy, fraction: 1.0)
        context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
        drawAnnotations(doc, width: strokeWidth(pixelSize: image.size))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    /// Small image for menus — annotations included, so a screenshot looks in the list the
    /// way it will land in the clipboard.
    static func thumbnail(image: NSImage, doc: EditDoc, height: CGFloat) -> NSImage? {
        let rect = canvasRect(pixelSize: image.size, doc: doc)
        guard rect.height > 0 else { return nil }
        let width = max(1, round(rect.width * height / rect.height))
        let thumb = NSImage(size: NSSize(width: width, height: height))
        thumb.lockFocus()
        defer { thumb.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: rect,
                   operation: .copy, fraction: 1.0)
        if let ctx = NSGraphicsContext.current?.cgContext {
            let scale = width / rect.width
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            drawAnnotations(doc, width: strokeWidth(pixelSize: image.size))
        }
        return thumb
    }
}
