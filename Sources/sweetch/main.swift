import Cocoa

let app = NSApplication.shared
/// When sweetch started, for the window.
let launchedAt = Date()
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
// `sweetch --count-stats [metrics.json]`: the statistics and insights counted, and how long that took — the
// second time reads only what changed in between.
if CommandLine.arguments.contains("--count-stats") {
    for _ in 0..<2 {
        let start = Date()
        let m = Metrics.compute(), i = Insights.compute()
        Metrics.saveDigests()
        Insights.saveDigests()
        print(String(format: "%.2f s · %d days · %d taps", Date().timeIntervalSince(start),
                     (m["days"] as? [Any])?.count ?? 0, ((i["taps"] as? [String: Any])?["all"] as? Int) ?? 0))
        if let i = CommandLine.arguments.firstIndex(of: "--count-stats"), i + 1 < CommandLine.arguments.count {
            try? JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        }
    }
    exit(0)
}
// `sweetch --chat-probe <text file>`: two turns of the iPhone's talk about a dictation, cached as
// it caches — what each cost goes to llm-usage/ as usual (purpose "chat-probe").
if let i = CommandLine.arguments.firstIndex(of: "--chat-probe"), i + 1 < CommandLine.arguments.count {
    let text = (try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8)) ?? ""
    let done = DispatchSemaphore(value: 0)
    Task {
        var messages = [["role": "user", "content": "The dictation:\n\n\(text)\n\nSummarise it in a few sentences."]]
        for next in ["Shorter.", "Now in English."] {
            let reply = (try? await LLMClient.complete(system: "Rework the dictation as asked; reply with the text alone.",
                                                       messages: messages, maxTokens: 800, model: .smart,
                                                       purpose: "chat-probe", cache: true)) ?? "(failed)"
            print("→ \(reply.prefix(120))")
            messages += [["role": "assistant", "content": reply], ["role": "user", "content": next]]
        }
        done.signal()
    }
    done.wait()
    exit(0)
}
// `sweetch --render-main <section> out.png`: Sweetch's window, a section of it, into a PNG.
if let i = CommandLine.arguments.firstIndex(of: "--render-main"), i + 2 < CommandLine.arguments.count {
    let a = CommandLine.arguments
    let size = i + 4 < a.count ? Double(a[i + 3]).flatMap { w in Double(a[i + 4]).map { NSSize(width: w, height: $0) } } : nil
    MainWindow.render(a[i + 1], to: URL(fileURLWithPath: a[i + 2]), size: size)
    exit(0)
}
// `sweetch --serve`: only the iPhone's dictation server, with no menu, keys or windows — for a Mac
// nobody sits at (the Mac mini, run by launchd: see `make mini`).
if CommandLine.arguments.contains("--serve") {
    let server = DictationServer()
    server.start()
    Stats.start()
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
