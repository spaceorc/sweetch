import Foundation

/// What a file comes to once read, kept on disk beside the next launch: a file whose size and date
/// haven't changed is never read again. The keyboard's logs are tens of megabytes a day, mostly
/// touches; the dictations are a folder each — read once, they stay read.
final class DigestCache<Value: Codable>: @unchecked Sendable {
    private struct Item: Codable {
        let size: Int
        let modified: Double
        let value: Value
    }

    private let url: URL
    private let lock = NSLock()
    private var items: [String: Item]
    private var dirty = false

    /// `version`: bumped when what a digest holds changes, so old ones are dropped, not misread.
    init(_ name: String, version: Int) {
        url = Stats.dir.appendingPathComponent("\(name)-v\(version).json")
        items = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Item].self, from: $0) } ?? [:]
    }

    /// The file's digest — kept, or `read` now if the file is new or changed since.
    func value(for file: URL, read: (URL) -> Value) -> Value {
        let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? -1
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        if let item = lock.withLock({ items[file.path] }), item.size == size, item.modified == modified { return item.value }
        let value = read(file)
        lock.withLock {
            items[file.path] = Item(size: size, modified: modified, value: value)
            dirty = true
        }
        return value
    }

    /// Writes what changed, leaving out the files gone since (a dictation forgotten).
    func save() {
        let snapshot: [String: Item]? = lock.withLock {
            guard dirty else { return nil }
            dirty = false
            items = items.filter { FileManager.default.fileExists(atPath: $0.key) }
            return items
        }
        guard let snapshot, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Stats.dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// A log only ever added to (the keyboard's, a file a day), read as it grows: where reading stopped
/// and the reader's state there are kept on disk, a file of their own per log, and only the lines
/// added since are read. A log that isn't what was read before — shorter, or other bytes where
/// reading stopped (a copy from the other Mac that differs) — is read again from the start.
final class LogDigests<State: Codable>: @unchecked Sendable {
    private struct Item: Codable {
        var offset: Int
        /// The bytes just before `offset`, hashed: the same file still?
        var tail: UInt64
        var state: State
    }

    private let dir: URL
    private let lock = NSLock()
    private var items: [String: Item] = [:]
    private var loaded = Set<String>()
    private var dirty = Set<String>()

    init(_ name: String, version: Int) {
        dir = Stats.dir.appendingPathComponent("\(name)-v\(version)", isDirectory: true)
    }

    /// The reader's state at the log's end: `read` given the lines added since, whole lines only.
    func state(for file: URL, fresh: () -> State, read: (inout State, Substring) -> Void) -> State {
        let key = file.lastPathComponent
        var item: Item? = lock.withLock {
            if loaded.insert(key).inserted, let data = try? Data(contentsOf: dir.appendingPathComponent(key + ".json")) {
                items[key] = try? JSONDecoder().decode(Item.self, from: data)
            }
            return items[key]
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return item?.state ?? fresh() }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        if let i = item, i.offset > size || Self.tail(handle, before: i.offset) != i.tail { item = nil }
        var current = item ?? Item(offset: 0, tail: 0, state: fresh())
        guard size > current.offset else { return current.state }
        try? handle.seek(toOffset: UInt64(current.offset))
        guard let data = try? handle.read(upToCount: size - current.offset),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return current.state }
        let whole = data[data.startIndex...end]
        read(&current.state, Substring(String(decoding: whole, as: UTF8.self)))
        current.offset += whole.count
        current.tail = Self.tail(handle, before: current.offset)
        lock.withLock {
            items[key] = current
            dirty.insert(key)
        }
        return current.state
    }

    func save() {
        let changed: [(String, Item)] = lock.withLock {
            defer { dirty.removeAll() }
            return dirty.compactMap { key in items[key].map { (key, $0) } }
        }
        guard !changed.isEmpty else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (key, item) in changed {
            try? JSONEncoder().encode(item).write(to: dir.appendingPathComponent(key + ".json"), options: .atomic)
        }
    }

    /// FNV-1a of the 256 bytes before `offset`.
    private static func tail(_ handle: FileHandle, before offset: Int) -> UInt64 {
        let start = max(0, offset - 256)
        try? handle.seek(toOffset: UInt64(start))
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in (try? handle.read(upToCount: offset - start)) ?? Data() {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }

    /// A line's stable hash — for telling a line sent twice (a batch resent) across launches.
    static func lineHash(_ line: Substring) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

/// The statistics and insights, counted in the background and kept ready: once a while after
/// launch, every few minutes after, and soon after a dictation or a keyboard log comes in — each
/// time reading only what changed (DigestCache). The window, and the iPhone asking the server,
/// get the last count at once.
enum Stats {
    static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("sweetch/stats", isDirectory: true)

    private static let queue = DispatchQueue(label: "sweetch.stats", qos: .utility)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var metrics: [String: Any]?
    nonisolated(unsafe) private static var insights: [String: Any]?
    nonisolated(unsafe) private static var counted: Date?
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var pending = false

    /// Counting from now on: first after `delay`, then every five minutes.
    static func start(after delay: TimeInterval = 10) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + delay, repeating: 300, leeway: .seconds(30))
        t.setEventHandler { count() }
        t.resume()
        timer = t
        NotificationCenter.default.addObserver(forName: DictationStore.changed, object: nil, queue: nil) { _ in soon() }
    }

    /// Something new came in: counted again within half a minute, once however much comes.
    static func soon() {
        let go = lock.withLock { () -> Bool in
            guard !pending else { return false }
            pending = true
            return true
        }
        if go { queue.asyncAfter(deadline: .now() + 30) { count() } }
    }

    /// The last count of the metrics (Metrics.compute), counting now if there's none yet.
    static func currentMetrics() -> [String: Any] {
        if let m = lock.withLock({ metrics }) { return m }
        queue.sync { if lock.withLock({ metrics }) == nil { countNow() } }
        return lock.withLock { metrics } ?? [:]
    }

    static func currentInsights() -> [String: Any] {
        if let i = lock.withLock({ insights }) { return i }
        queue.sync { if lock.withLock({ insights }) == nil { countNow() } }
        return lock.withLock { insights } ?? [:]
    }

    /// When the numbers shown were counted.
    static var countedAt: Date? { lock.withLock { counted } }

    private static func count() {
        lock.withLock { pending = false }
        countNow()
    }

    /// On the queue only.
    private static func countNow() {
        let m = Metrics.compute()
        let i = Insights.compute()
        lock.withLock {
            metrics = m
            insights = i
            counted = Date()
        }
        Metrics.saveDigests()
        Insights.saveDigests()
    }
}
