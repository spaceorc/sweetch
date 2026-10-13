import Cocoa

let app = NSApplication.shared

// `sweetch --render-dictations out.png`: draw the Dictations window, dark, into a PNG and exit —
// for checking its layout without putting it on screen.
if let i = CommandLine.arguments.firstIndex(of: "--render-dictations"), i + 1 < CommandLine.arguments.count {
    app.appearance = NSAppearance(named: .darkAqua)
    let window = DictationsWindow()
    try? window.debugRenderContent()?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
