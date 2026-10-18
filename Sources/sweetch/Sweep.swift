import Foundation

/// `sweetch --sweep [--dry-run]`: goes through everything kept — the dictations, the Wispr Flow
/// history, the iPhone keyboard's log of closed days, the corrections history — and masks the
/// secrets in it (Secrets.swift) in place. A dictation with a secret loses its screenshot too
/// (whatever was in the text was likely on the screen), and a tombstone says so, so that the Mac
/// mini drops its copy and the sync doesn't bring it back. Prints counts only, never a value.
enum Sweep {
    static func run(dryRun: Bool) {
        var found: [String: Int] = [:]          // kind → how many
        var files: [String: Int] = [:]          // what was masked → how many files
        var screenshots = 0
        let fm = FileManager.default
        let root = AppSupport.dir

        func sweep(json url: URL, label: String) -> Bool {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return false }
            var kinds: [String] = []
            var masked = Secrets.mask(object, kinds: &kinds)
            guard !kinds.isEmpty else { return false }
            if var d = masked as? [String: Any], d["screenshot"] != nil { d["screenshot"] = nil; masked = d }
            for k in kinds { found[k, default: 0] += 1 }
            files[label, default: 0] += 1
            if !dryRun, let out = try? JSONSerialization.data(withJSONObject: masked, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
                try? out.write(to: url, options: .atomic)
            }
            return true
        }

        func folders(_ dir: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }

        // The dictations, and the Wispr Flow history: a folder each.
        for (dir, label, shots) in [(root.appendingPathComponent("dictation"), "dictation", ["window.png"]),
                                    (root.appendingPathComponent("wispr-flow/history"), "wispr-flow", [])] {
            for folder in folders(dir) {
                let jsons = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "json" }
                var hit = false
                for json in jsons where sweep(json: json, label: "\(label)/\(json.lastPathComponent)") { hit = true }
                guard hit else { continue }
                for shot in shots where fm.fileExists(atPath: folder.appendingPathComponent(shot).path) {
                    screenshots += 1
                    let path = folder.appendingPathComponent(shot)
                    if !dryRun {
                        try? fm.removeItem(at: path)
                        Tombstones.add(path, why: "secret")
                    }
                }
            }
        }

        // Line by line: the keyboard's log (only days that are over — today's is still being
        // written, here or on the Mac mini, and a later copy would win the sync) and the
        // corrections history.
        let today = String(DictationStore.stamp(Date()).prefix(10))
        var logs = ((try? fm.contentsOfDirectory(at: root.appendingPathComponent("keyboard"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.prefix(10) < today }
            .map { ($0, "keyboard log") }
        logs.append((AppSupport.history, "history.jsonl"))
        for (url, label) in logs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            var changed = false
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                guard line.contains(where: { $0.isLetter || $0.isNumber }),
                      let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else { return String(line) }
                var kinds: [String] = []
                let masked = Secrets.mask(object, kinds: &kinds)
                guard !kinds.isEmpty, let out = try? JSONSerialization.data(withJSONObject: masked, options: [.sortedKeys, .withoutEscapingSlashes]),
                      let s = String(data: out, encoding: .utf8) else { return String(line) }
                for k in kinds { found[k, default: 0] += 1 }
                changed = true
                return s
            }
            guard changed else { continue }
            files[label, default: 0] += 1
            if !dryRun { try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        }

        print(dryRun ? "would mask (dry run):" : "masked:")
        for (k, n) in found.sorted(by: { $0.value > $1.value }) { print("  \(k): \(n)") }
        print("in files:")
        for (k, n) in files.sorted(by: { $0.value > $1.value }) { print("  \(k): \(n)") }
        print("screenshots \(dryRun ? "to remove" : "removed"): \(screenshots)")
        if found.isEmpty { print("  nothing found") }
    }
}

/// What was removed on purpose, so it stays removed: the sync copies whatever is new on either
/// Mac and never deletes, so a file removed here would come back from the Mac mini. One file per
/// Mac (`tombstones/<host>.jsonl`, append only), synced first; Tools/mini/sync.sh removes every
/// path in them on both sides before copying anything. A path and when — never what was in it.
enum Tombstones {
    static var dir: URL { AppSupport.dir.appendingPathComponent("tombstones", isDirectory: true) }

    static func add(_ url: URL, why: String) {
        let base = AppSupport.dir.standardizedFileURL.path + "/"
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(base) else { return }
        let path = String(full.dropFirst(base.count))
        let host = (ProcessInfo.processInfo.hostName.split(separator: ".").first.map(String.init) ?? "mac").lowercased()
        let line: [String: Any] = ["at": DictationStore.stamp(Date()), "path": path, "why": why]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(host).jsonl")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: file)
        }
    }
}

/// Where a dictation goes when the user forgets it: out of the synced folders, to a folder of its
/// own beside them (`sweetch-private/quarantine`), kept out of Time Machine, for thirty days — so a
/// slip can still be looked at or undone by hand — then gone. The tombstone takes the Mac mini's
/// copy away at the next sync.
enum Quarantine {
    static var dir: URL {
        AppSupport.dir.deletingLastPathComponent().appendingPathComponent("sweetch-private/quarantine", isDirectory: true)
    }

    /// Moves `folder` (a dictation) to the quarantine; false when there was nothing to move.
    @discardableResult
    static func take(_ folder: URL, why: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path) else { return false }
        var target = dir
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
        target.appendPathComponent(folder.lastPathComponent)
        try? fm.removeItem(at: target)
        guard (try? fm.moveItem(at: folder, to: target)) != nil else { return false }
        Tombstones.add(folder, why: why)
        DispatchQueue.main.async { NotificationCenter.default.post(name: DictationStore.changed, object: folder) }
        return true
    }

    /// Whatever has been in the quarantine for thirty days, gone for good.
    static func purge() {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-30 * 24 * 3600)
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date < old { try? fm.removeItem(at: item) }
        }
    }
}

extension Sweep {
    /// Bumped whenever Secrets learns something new: everything kept is swept again once, in the
    /// background, at the next launch.
    static let version = 1

    static func runIfNew() {
        guard UserDefaults.standard.integer(forKey: "sweepVersion") < version else { return }
        DispatchQueue.global(qos: .background).async {
            run(dryRun: false)
            UserDefaults.standard.set(version, forKey: "sweepVersion")
        }
    }
}
