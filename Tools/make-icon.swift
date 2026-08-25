import Cocoa

// Renders the app icon at 1024 and writes it as a PNG. Run through `make icon`, which turns
// the result into Contents/Resources/AppIcon.icns — the Dock reads the bundle icon, and a
// runtime applicationIconImage alone isn't reliably picked up when an accessory app switches
// to a regular activation policy.
let side: CGFloat = 1024
let out = CommandLine.arguments[1]

let icon = NSImage(size: NSSize(width: side, height: side))
icon.lockFocus()

// macOS icons leave a margin and use a squircle-ish radius of about 22% of the side.
let inset = side * 0.08
let body = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
                        xRadius: side * 0.2, yRadius: side * 0.2)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.27, blue: 0.36, alpha: 1),
    NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.21, alpha: 1),
])
gradient?.draw(in: body, angle: -90)

// Colour must be baked into the symbol configuration: a template image drawn straight into
// a context keeps its own black instead of picking up the current colour.
let config = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let glyph = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "sweetch")?
    .withSymbolConfiguration(config) {
    let width = side * 0.56, height = width * (glyph.size.height / glyph.size.width)
    glyph.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height),
               from: .zero, operation: .sourceOver, fraction: 1.0)
}
icon.unlockFocus()

let rep = NSBitmapImageRep(data: icon.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
