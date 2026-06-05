import Darwin
import Foundation
import SyncCore

/// Manages the per-user LaunchAgent that runs `--once` on a schedule. The plist lives at
/// `~/Library/LaunchAgents/<label>.plist`. Install is idempotent (bootout-then-bootstrap),
/// with an unload/load fallback for older macOS.
enum LaunchdAgent {
    /// Stable identifier — kept aligned with the code-signing identifier in `sign.sh`.
    static let label = "com.kerim.logseq-reminders-sync"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// Write the plist (pointing at an absolute binary path) and (re)load the agent.
    static func install(binaryPath: String, intervalSeconds: Int) throws {
        let logDir = Config.configDir.appendingPathComponent("log")
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let outPath = logDir.appendingPathComponent("launchd.out.log").path
        let errPath = logDir.appendingPathComponent("launchd.err.log").path

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>--once</string>
            </array>
            <key>StartInterval</key>
            <integer>\(intervalSeconds)</integer>
            <key>ProcessType</key>
            <string>Background</string>
            <key>StandardOutPath</key>
            <string>\(outPath)</string>
            <key>StandardErrorPath</key>
            <string>\(errPath)</string>
        </dict>
        </plist>
        """

        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try plist.data(using: .utf8)!.write(to: plistURL, options: .atomic)
        reload()
    }

    /// bootout (ignore "not loaded"), enable (clear any durable disable), then bootstrap.
    /// Falls back to unload/load. The enable() call ensures that a label durably disabled
    /// by `pause` is re-activated before bootstrap — launchd silently refuses bootstrap
    /// on a disabled label.
    static func reload() {
        bootout()
        _ = enable()
        if !bootstrap() {
            _ = runLaunchctl(["load", "-w", plistURL.path])
        }
    }

    /// The per-user GUI launchd domain (`gui/<uid>`) the agent lives in.
    private static var guiDomain: String { "gui/\(getuid())" }

    /// Stop and unload the agent. Safe to call when not loaded.
    @discardableResult
    static func bootout() -> Bool {
        if runLaunchctl(["bootout", "\(guiDomain)/\(label)"]) { return true }
        return runLaunchctl(["unload", plistURL.path])
    }

    /// Load and start the agent from the on-disk plist.
    @discardableResult
    static func bootstrap() -> Bool {
        if runLaunchctl(["bootstrap", guiDomain, plistURL.path]) { return true }
        return runLaunchctl(["load", "-w", plistURL.path])
    }

    /// Durably disable the agent label so launchd won't restart it across logout/reboot.
    /// Not @discardableResult — callers that intentionally discard must write `_ = disable()`.
    static func disable() -> Bool {
        runLaunchctl(["disable", "\(guiDomain)/\(label)"])
    }

    /// Clear a prior durable disable. Must be called before `bootstrap()` when the label
    /// was durably disabled — launchd silently refuses bootstrap on a disabled label.
    /// Not @discardableResult — callers that intentionally discard must write `_ = enable()`.
    static func enable() -> Bool {
        runLaunchctl(["enable", "\(guiDomain)/\(label)"])
    }

    /// Stop the running instance, durably disable the label, and delete the plist.
    /// Safe to call when the agent is not running or the plist is already absent.
    static func remove() {
        bootout()
        _ = disable()
        try? FileManager.default.removeItem(at: plistURL)
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
