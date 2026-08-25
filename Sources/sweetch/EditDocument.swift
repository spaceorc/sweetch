import Cocoa

/// One arrow, in original image pixel coordinates (origin bottom-left, matching AppKit's
/// unflipped drawing). Both ends stay addressable so they can be dragged later.
struct Arrow: Codable, Equatable {
    var id: UUID = UUID()
    var from: CGPoint
    var to: CGPoint
}

/// Everything laid on top of an image. Never baked into the file: the PNG on disk stays the
/// untouched capture and this lives beside it, so every arrow and the crop frame remain
/// editable forever. Only the clipboard ever gets a flattened render.
struct EditDoc: Codable, Equatable {
    var arrows: [Arrow] = []
    /// Crop is a *view* onto the original, not a destructive trim — drag it around, or undo
    /// it, and the pixels outside come straight back.
    var crop: CGRect?
    /// The frame being drawn in crop mode, before it's applied. Kept in the document (and so
    /// in the history) on purpose: drawing the frame and applying it are two separate edits
    /// that undo separately.
    var cropFrame: CGRect?

    var isEmpty: Bool { arrows.isEmpty && crop == nil && cropFrame == nil }

    func arrow(_ id: UUID?) -> Arrow? {
        guard let id else { return nil }
        return arrows.first { $0.id == id }
    }
}

/// The document plus its undo/redo stacks, persisted as a whole. Snapshot-based rather than
/// command-based: the document is tiny, so copying it costs nothing, and "reopen tomorrow
/// and keep pressing undo" falls out for free.
struct EditHistory: Codable {
    var doc = EditDoc()
    var undoStack: [EditDoc] = []
    var redoStack: [EditDoc] = []

    private static let maxDepth = 100

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func commit(_ change: (inout EditDoc) -> Void) {
        let before = doc
        change(&doc)
        guard doc != before else { return }   // a drag that went nowhere isn't an undo step
        undoStack.append(before)
        if undoStack.count > Self.maxDepth { undoStack.removeFirst() }
        redoStack.removeAll()                 // a fresh edit forks the timeline
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
    }
}

/// A live editing session over one image file: history in memory, sidecar on disk.
///
/// The sidecar lives in a hidden `.edits` subfolder rather than next to the PNG, so the
/// screenshot folder stays clean when you open it in Finder. The trade-off is that renaming
/// or moving a screenshot outside sweetch orphans its edits.
final class EditSession {
    let imageURL: URL
    private(set) var history: EditHistory
    /// Document as it was when an interactive drag started — lets a whole drag land as one
    /// undo step instead of a hundred.
    private var dragBaseline: EditDoc?

    var doc: EditDoc { history.doc }
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    init(imageURL: URL) {
        self.imageURL = imageURL
        self.history = EditSession.load(for: imageURL) ?? EditHistory()
    }

    func commit(_ change: (inout EditDoc) -> Void) {
        history.commit(change)
        save()
    }

    /// Live-edit without touching the history — used while dragging.
    func updateLive(_ change: (inout EditDoc) -> Void) {
        if dragBaseline == nil { dragBaseline = history.doc }
        change(&history.doc)
    }

    /// Fold everything that happened since `updateLive` began into a single undo step.
    func endLiveEdit() {
        guard let baseline = dragBaseline else { return }
        dragBaseline = nil
        let final = history.doc
        history.doc = baseline
        history.commit { $0 = final }
        save()
    }

    func undo() { history.undo(); save() }
    func redo() { history.redo(); save() }

    // MARK: - Sidecar

    static func sidecarURL(for imageURL: URL) -> URL {
        let dir = imageURL.deletingLastPathComponent().appendingPathComponent(".edits", isDirectory: true)
        return dir.appendingPathComponent(imageURL.lastPathComponent + ".json")
    }

    static func load(for imageURL: URL) -> EditHistory? {
        guard let data = try? Data(contentsOf: sidecarURL(for: imageURL)) else { return nil }
        do {
            return try JSONDecoder().decode(EditHistory.self, from: data)
        } catch {
            log.error("sidecar: unreadable for \(imageURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save() {
        let url = Self.sidecarURL(for: imageURL)
        // Nothing drawn and nothing to undo — don't leave an empty sidecar behind.
        if history.doc.isEmpty && !history.canUndo && !history.canRedo {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(history).write(to: url, options: .atomic)
        } catch {
            log.error("sidecar: save failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
