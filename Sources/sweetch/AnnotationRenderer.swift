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
    static func drawArrows(_ doc: EditDoc, width: CGFloat) {
        NSColor.systemRed.setFill()
        for arrow in doc.arrows {
            arrowPath(from: arrow.from, to: arrow.to, width: width).fill()
        }
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

    /// Distance from a point to the arrow's shaft — hit testing for selection.
    static func distance(from point: CGPoint, to arrow: Arrow) -> CGFloat {
        let a = arrow.from, b = arrow.to
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
        drawArrows(doc, width: strokeWidth(pixelSize: image.size))
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
            drawArrows(doc, width: strokeWidth(pixelSize: image.size))
        }
        return thumb
    }
}
