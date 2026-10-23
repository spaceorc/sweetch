import Cocoa

let app = NSApplication.shared
// Every call to a model, and what it cost — the probes' too.
LLMUsage.sink = LLMUsageLog.append
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []

// `sweetch --rehear <dictation folder>…`: run stored dictations through today's pipeline.
// `sweetch --next-word-probe <cases.json> <out.json>`: the model guessing the next word typed.
if let i = CommandLine.arguments.firstIndex(of: "--next-word-probe"), i + 2 < CommandLine.arguments.count {
    NextWordProbe.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]), URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(0)
}

// `sweetch --fill-probe <cases.json> <out.json>`: the model filling in a dictated word marked wrong.
if let i = CommandLine.arguments.firstIndex(of: "--fill-probe"), i + 2 < CommandLine.arguments.count {
    FillProbe.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]), URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(0)
}

// `sweetch --learn-probe <cases.json> <out.json>`: settling again, told what corrections taught.
if let i = CommandLine.arguments.firstIndex(of: "--learn-probe"), i + 2 < CommandLine.arguments.count {
    LearnProbe.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]), URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    exit(0)
}

// `sweetch --sweep [--dry-run]`: mask the secrets in everything kept (Sweep.swift).
if CommandLine.arguments.contains("--sweep") {
    Sweep.run(dryRun: CommandLine.arguments.contains("--dry-run"))
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--rehear") {
    Rehear.run(CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) })
    exit(0)
}

// `sweetch --theirs <dictation folder>…`: read again what an app's own dictation wrote.
if let i = CommandLine.arguments.firstIndex(of: "--theirs") {
    Theirs.rerun(CommandLine.arguments[(i + 1)...].map { URL(fileURLWithPath: $0) })
    exit(0)
}

// `sweetch --render-dictations out.png`: draw the Dictations window, dark, into a PNG and exit —
// for checking its layout without putting it on screen.
if let i = CommandLine.arguments.firstIndex(of: "--render-dictations"), i + 1 < CommandLine.arguments.count {
    app.appearance = NSAppearance(named: .darkAqua)
    let window = DictationsWindow()
    try? window.debugRenderContent()?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}
// `sweetch --serve`: only the iPhone's dictation server, with no menu, keys or windows — for a Mac
// nobody sits at (the Mac mini, run by launchd: see `make mini`).
if CommandLine.arguments.contains("--serve") {
    let server = DictationServer()
    server.start()
    for signo in [SIGTERM, SIGINT] {
        signal(signo, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signo, queue: .main)
        source.setEventHandler {
            server.stop()
            Whisper.shutDown()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
    if let missing = Whisper.missing() { log.error("dictation server: missing \(missing, privacy: .public)") }
    dispatchMain()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
