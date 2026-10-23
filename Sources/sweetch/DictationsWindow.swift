import Cocoa

/// Every dictation, newest first, and everything about the one selected: what was typed, how each
/// listening heard it, the prefix it was primed with, what the model settled on and from what
/// context, and what the user made of it afterwards. Holds handed to an app's own dictation (Claude
/// desktop, Claude Code) are listed too.
///
/// Reads the folders `DictationStore` writes, and follows them as they change.
final class DictationsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private let table = NSTableView()
    private let detail = NSTextView()
    private let playButton = NSButton(title: "Play Recording", target: nil, action: nil)
    private let finderButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let screenshotButton = NSButton(title: "Open Screenshot", target: nil, action: nil)
    private var entries: [Entry] = []
    private var sound: NSSound?

    /// One dictation folder; the list reads only `session.json`, the detail reads the rest.
    struct Entry {
        let dir: URL
        let date: Date
        let session: [String: Any]

        var app: String { session["app"] as? String ?? "?" }

        var summary: String {
            if let to = session["handoff"] as? String {
                guard session["shadow"] as? Bool == true else { return "→ \(to)’s own dictation" }
                let theirs = session["theirs"] as? String ?? "?"
                let ours = session["text"] as? String
                let same = ours.map { $0.lowercased().filter(\.isLetter) == theirs.lowercased().filter(\.isLetter) } ?? false
                return "→ \(to): \(theirs)" + (ours == nil || same ? "" : "   ≠ ours: \(ours!)")
            }
            if session["cancelled"] as? Bool == true { return "cancelled" }
            if let skipped = session["skipped"] as? String { return skipped }
            if let error = session["error"] as? String { return "error: \(error)" }
            if let typed = session["inserted"] as? String { return typed.trimmingCharacters(in: .whitespaces) }
            if let copied = session["copied"] as? String { return "copied: \(copied)" }
            if session.isEmpty { return "listening…" }
            return "nothing heard"
        }

        var isHandoff: Bool { session["handoff"] != nil }

        func json(_ name: String) -> [String: Any] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object
        }
    }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Dictations"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 420)
        window.setFrameAutosaveName("sweetch.dictations")
        buildContent()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(dictationsChanged),
                                               name: DictationStore.changed, object: nil)
    }

    func show() {
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func buildContent() {
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 46
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        detail.isEditable = false
        detail.isSelectable = true
        detail.drawsBackground = true
        detail.backgroundColor = .textBackgroundColor
        detail.textContainerInset = NSSize(width: 18, height: 16)
        detail.isVerticallyResizable = true
        detail.autoresizingMask = [.width]
        detail.textContainer?.widthTracksTextView = true
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true

        for (button, action) in [(playButton, #selector(play)), (finderButton, #selector(showInFinder)),
                                 (screenshotButton, #selector(openScreenshot))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        let buttons = NSStackView(views: [playButton, finderButton, screenshotButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        let right = NSStackView(views: [buttons, detailScroll])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 0
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(right)
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        right.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        window.contentView = split
        split.setPosition(360, ofDividerAt: 0)
    }

    // MARK: - Data

    private func reload() {
        let selected = table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow].dir : nil
        let dirs = (try? FileManager.default.contentsOfDirectory(at: DictationStore.dir, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        entries = dirs
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(500)
            .map { dir in
                let session = Entry(dir: dir, date: Date(), session: [:]).json("session.json")
                return Entry(dir: dir, date: Self.date(of: dir, session: session), session: session)
            }
        table.reloadData()
        let row = selected.flatMap { dir in entries.firstIndex { $0.dir == dir } } ?? (entries.isEmpty ? -1 : 0)
        if row >= 0 {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        showDetail()
    }

    private static let folderFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
        return f
    }()

    private static func date(of dir: URL, session: [String: Any]) -> Date {
        folderFormatter.date(from: dir.lastPathComponent) ?? Date.distantPast
    }

    @objc private func dictationsChanged(_ note: Notification) {
        reload()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("row")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let label = NSTextField(labelWithString: "")
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let entry = entries[row]
        let line = NSMutableAttributedString(
            string: "\(Self.listTime(entry.date))  ·  \(entry.app)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        line.append(NSAttributedString(string: entry.summary, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: entry.isHandoff ? .regular : .medium),
            .foregroundColor: entry.isHandoff ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]))
        cell.textField?.attributedStringValue = line
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showDetail()
    }

    private static func listTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "d MMM HH:mm"
        return f.string(from: date)
    }

    // MARK: - Detail

    private var selectedEntry: Entry? {
        table.selectedRow >= 0 && table.selectedRow < entries.count ? entries[table.selectedRow] : nil
    }

    private func showDetail() {
        let entry = selectedEntry
        let wav = entry?.dir.appendingPathComponent("recording.wav")
        playButton.isEnabled = wav.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        finderButton.isEnabled = entry != nil
        screenshotButton.isEnabled = entry.map { FileManager.default.fileExists(atPath: $0.dir.appendingPathComponent("window.png").path) } ?? false
        detail.textStorage?.setAttributedString(entry.map(DetailWriter.write) ?? NSAttributedString())
        detail.scrollToBeginningOfDocument(nil)
    }

    @objc private func play() {
        guard let wav = selectedEntry?.dir.appendingPathComponent("recording.wav") else { return }
        sound?.stop()
        sound = NSSound(contentsOf: wav, byReference: true)
        sound?.play()
    }

    @objc private func showInFinder() {
        guard let dir = selectedEntry?.dir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func openScreenshot() {
        guard let png = selectedEntry?.dir.appendingPathComponent("window.png") else { return }
        NSWorkspace.shared.open(png)
    }

    func windowWillClose(_ notification: Notification) {
        sound?.stop()
        NotificationCenter.default.removeObserver(self)
        onClose?()
    }

    /// Renders the window's content to a PNG without showing it — for checking the layout.
    func debugRenderContent() -> Data? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

/// The detail of one dictation as styled text.
enum DetailWriter {
    static func write(_ entry: DictationsWindow.Entry) -> NSAttributedString {
        var w = Writer()
        let s = entry.session

        if let to = s["handoff"] as? String {
            w.title("Handed to \(to)")
            w.line("\(entry.app) has a dictation of its own, so the hold went to it.", .secondary)
            if let seconds = s["hold_seconds"] as? Double { w.line("Held for \(secs(seconds)).", .secondary) }
            guard s["shadow"] as? Bool == true else { return w.text }
            w.heading("\(to) vs. us")
            w.labelled("\(to) wrote", s["theirs"] as? String ?? "(couldn't tell from the field)")
            w.labelled("We heard", s["text"] as? String ?? "(nothing)")
            if let r = s["seconds"] as? Double { w.line("we took \(secs(r)) after release", .secondary) }
        } else {

        // The outcome.
        w.title(entry.summary.isEmpty ? "—" : entry.summary)
        var timings: [String] = []
        if let r = s["recording_seconds"] as? Double { timings.append("spoke \(secs(r))") }
        if let r = s["seconds"] as? Double { timings.append("recognised in \(secs(r)) after release") }
        if let settle = s["settlement"] as? [String: Any], let r = settle["seconds"] as? Double { timings.append("of which the model \(secs(r))") }
        w.line(([entry.app] + timings).joined(separator: "  ·  "), .secondary)
        }

        // What the user made of it.
        let followup = entry.json("followup.json")
        if !followup.isEmpty {
            w.heading("Afterwards")
            let ended = followup["ended_by"] as? String ?? "?"
            if let after = followup["field_after_insert"] as? String, let final = followup["field_final"] as? String {
                if let (was, became) = changed(from: after, to: final) {
                    w.line("Edited before \(ended):", .secondary)
                    w.mono("− \(was)\n+ \(became)")
                } else {
                    w.line("Kept as typed (until \(ended)).", .secondary)
                }
            } else {
                w.line("Ended by \(ended); the field couldn't be read.", .secondary)
            }
        }

        // The prefix.
        let prefix = entry.json("prefix.json")
        w.heading("Prefix")
        if prefix.isEmpty {
            w.line("None.", .secondary)
        } else {
            var how: [String] = []
            if let c = prefix["context_seconds"] as? Double { how.append("context gathered in \(secs(c))") }
            if let t = prefix["seconds"] as? Double { how.append("ready \(secs(t)) after the hold began") }
            if !how.isEmpty { w.line(how.joined(separator: "  ·  "), .secondary) }
            if let spoken = prefix["spoken"] as? String { w.labelled("Written by the model", spoken) }
            if let spoken = prefix["spoken"] as? [String: String] {
                for (language, text) in spoken.sorted(by: { $0.key > $1.key }) { w.labelled("Written by the model — \(language)", text) }
            }
            if let preceding = prefix["preceding"] as? String { w.labelled("From the field", preceding, mono: true) }
            if let listenings = s["listenings"] as? [[String: Any]], !listenings.contains(where: { $0["prefixed"] as? Bool == true }) {
                let skipped = (s["settlement"] as? [String: Any])?["skipped"] as? String ?? ""
                if skipped.contains("bare listening") {
                    w.line("Not needed: Apple's recogniser agreed with the listening without it.", .secondary)
                } else {
                    w.line("Not used: it wasn't ready in time.", .warning)
                }
            }
        }

        // The listenings.
        if let listenings = s["listenings"] as? [[String: Any]] {
            w.heading("Listenings")
            for l in listenings {
                var head = [l["kind"] as? String ?? l["language"] as? String ?? "?",
                            (l["prefixed"] as? Bool ?? false) ? "with prefix" : "no prefix"]
                if let lang = l["language"] as? String { head.append("heard as \(lang)") }
                if let p = l["language_probabilities"] as? [String: Double], !p.isEmpty {
                    head.append(p.sorted { $0.value > $1.value }.map { "\($0.key) \(String(format: "%.2f", $0.value))" }.joined(separator: " "))
                }
                if let t = l["seconds"] as? Double { head.append(secs(t)) }
                w.line(head.joined(separator: "  ·  "), .secondary)
                let text = l["text"] as? String ?? ""
                w.line(text.isEmpty ? "(nothing)" : text, .body)
                if let unsure = l["uncertain"] as? [[String: Any]], !unsure.isEmpty {
                    let words = unsure.map { "\($0["word"] as? String ?? "?") \(String(format: "%.2f", $0["p"] as? Double ?? 0))" }
                    w.line("unsure: " + words.joined(separator: ", "), .warning)
                }
                w.gap()
            }
        }

        // The settling.
        if let settlement = s["settlement"] as? [String: Any] {
            w.heading("Settled by the model")
            if let skipped = settlement["skipped"] as? String {
                w.line("Not asked: \(skipped).", .secondary)
            } else {
                if let reply = settlement["reply"] as? String {
                    if let reasoning = LLMJSON.string(reply, key: "reasoning") { w.labelled("Reasoning", reasoning) }
                    if let text = LLMJSON.string(reply, key: "text") { w.labelled("Answer", text) }
                    w.labelled("Raw reply", reply, mono: true)
                } else {
                    w.line("The model didn't answer; the first version was typed.", .warning)
                }
                if let input = settlement["input"] as? String { w.labelled("What the model was given", input, mono: true) }
            }
        }

        // The context.
        let context = entry.json("context.json")
        if !context.isEmpty {
            w.heading("Context")
            var where_ = [context["app"] as? String ?? entry.app]
            if let title = context["window_title"] as? String { where_.append("“\(title)”") }
            w.line(where_.joined(separator: "  ·  "), .secondary)
            if let png = context["screenshot"] as? String { w.image(entry.dir.appendingPathComponent(png)) }
            if let field = context["field"] as? [String: Any], let value = field["value"] as? String, !value.isEmpty {
                w.labelled("Field (\(field["role"] as? String ?? "?"))", String(value.suffix(1500)), mono: true)
            }
            if let texts = context["window_texts"] as? [String], !texts.isEmpty {
                w.labelled("Window texts through Accessibility (\(texts.count))", String(texts.joined(separator: "\n").prefix(4000)), mono: true)
            }
            if let ocr = context["ocr"] as? String, !ocr.isEmpty {
                w.labelled("Read off the screenshot", String(ocr.prefix(4000)), mono: true)
            }
        }

        if let error = s["error"] as? String {
            w.heading("Error")
            w.mono(error)
        }
        return w.text
    }

    /// The span that differs between two texts, with a little of what surrounds it.
    private static func changed(from a: String, to b: String) -> (String, String)? {
        guard a != b else { return nil }
        let x = Array(a), y = Array(b)
        var start = 0
        while start < x.count, start < y.count, x[start] == y[start] { start += 1 }
        var endX = x.count, endY = y.count
        while endX > start, endY > start, x[endX - 1] == y[endY - 1] { endX -= 1; endY -= 1 }
        let lead = max(0, start - 30)
        let tailX = min(x.count, endX + 30), tailY = min(y.count, endY + 30)
        let show = { (c: [Character], from: Int, to: Int, tail: Int) -> String in
            (from > 0 ? "…" : "") + String(c[from..<tail]) + (tail < c.count ? "…" : "")
        }
        return (show(x, lead, endX, tailX), show(y, lead, endY, tailY))
    }

    private static func secs(_ s: Double) -> String { String(format: "%.2fs", s) }

    private struct Writer {
        enum Style { case body, secondary, warning }
        let text = NSMutableAttributedString()

        private func add(_ string: String, _ attributes: [NSAttributedString.Key: Any]) {
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        private static func paragraph(after: CGFloat = 2, before: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.paragraphSpacing = after
            p.paragraphSpacingBefore = before
            p.lineSpacing = 1.5
            return p
        }

        func title(_ s: String) {
            add(s + "\n", [.font: NSFont.systemFont(ofSize: 20, weight: .semibold), .foregroundColor: NSColor.labelColor,
                           .paragraphStyle: Self.paragraph(after: 4)])
        }

        func heading(_ s: String) {
            add(s.uppercased() + "\n", [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor,
                                        .kern: 0.6, .paragraphStyle: Self.paragraph(after: 6, before: 18)])
        }

        func line(_ s: String, _ style: Style) {
            let color: NSColor = switch style {
            case .body: .labelColor
            case .secondary: .secondaryLabelColor
            case .warning: .systemOrange
            }
            add(s + "\n", [.font: NSFont.systemFont(ofSize: style == .body ? 14 : 12), .foregroundColor: color,
                           .paragraphStyle: Self.paragraph()])
        }

        func labelled(_ label: String, _ value: String, mono: Bool = false) {
            add(label + "\n", [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.secondaryLabelColor,
                               .paragraphStyle: Self.paragraph(after: 1, before: 6)])
            if mono { self.mono(value) } else { line(value, .body) }
        }

        func mono(_ s: String) {
            add(s + "\n", [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor,
                           .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.08),
                           .paragraphStyle: Self.paragraph(after: 4)])
        }

        func gap() {
            add("\n", [.font: NSFont.systemFont(ofSize: 4)])
        }

        func image(_ url: URL) {
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else { return }
            let width: CGFloat = 520
            let scaled = NSImage(size: NSSize(width: width, height: width * image.size.height / image.size.width), flipped: false) { rect in
                image.draw(in: rect)
                return true
            }
            let attachment = NSTextAttachment()
            attachment.image = scaled
            text.append(NSAttributedString(attachment: attachment))
            add("\n", [.paragraphStyle: Self.paragraph(after: 8)])
        }
    }
}
