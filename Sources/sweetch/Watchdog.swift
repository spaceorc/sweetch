import Cocoa
import ServiceManagement

/// A launchd agent that owns sweetch's lifecycle: starts it at login and brings it back if
/// it dies abnormally. A menu-bar app that crashes just silently vanishes — there's no
/// window to notice missing — so without this the first sign of trouble is the user
/// wondering where their program went.
///
/// launchd only supervises processes it started itself, so installing the agent hands the
/// running instance over: the agent spawns a fresh copy, which asks the old one to quit
/// (see AppDelegate's newest-instance-wins guard).
enum Watchdog {
    static let label = "com.spaceorc.sweetch.watchdog"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/sweetch-watchdog.log")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func install() {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/sweetch").path
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Restart only after an abnormal exit. Quitting from the menu is a clean exit,
            // and must stay quit.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            log.error("watchdog: writing the job failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // The agent covers launch-at-login, so drop the login item — two launchers would
        // race to start two copies at every login.
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
            log.info("watchdog: login item unregistered, the agent covers it")
        }

        _ = launchctl(["bootout", domain + "/" + label])   // in case an older job is loaded
        let ok = launchctl(["bootstrap", domain, plistURL.path])
        log.info("watchdog: installed (bootstrap ok=\(ok, privacy: .public)) -> \(executable, privacy: .public)")
    }

    static func uninstall() {
        _ = launchctl(["bootout", domain + "/" + label])
        try? FileManager.default.removeItem(at: plistURL)
        log.info("watchdog: removed")
    }

    private static var domain: String { "gui/\(getuid())" }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            log.error("watchdog: launchctl \(arguments.first ?? "", privacy: .public) failed to run")
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
