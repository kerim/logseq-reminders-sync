import Foundation
import SyncCore

// MARK: - GitHub fetch

/// Fetches the tag name of the latest GitHub release.
/// Returns nil when no releases exist (404). Throws on any other failure.
private func fetchLatestReleaseTag() async throws -> String? {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest  = 5    // inactivity timer
    cfg.timeoutIntervalForResource = 15   // hard wall-clock ceiling
    cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
    let session = URLSession(configuration: cfg)

    var req = URLRequest(url: URL(string: "https://api.github.com/repos/kerim/logseq-reminders-sync/releases/latest")!)
    req.setValue("logseq-reminders-sync", forHTTPHeaderField: "User-Agent")
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

    let (data, response) = try await session.data(for: req)

    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 404 { return nil }
    guard status == 200 else {
        throw UpdateCheckError.httpError(status: status)
    }

    struct Release: Decodable { let tag_name: String }
    let release = try JSONDecoder().decode(Release.self, from: data)
    return release.tag_name
}

// MARK: - Notification banner

/// Displays a macOS notification banner via osascript. Best-effort; never throws.
private func displayUpdateNotification(title: String, message: String) {
    let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
    let safeMsg   = message.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "display notification \"\(safeMsg)\" with title \"\(safeTitle)\""

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    p.standardOutput = Pipe()
    p.standardError  = Pipe()
    do { try p.run() } catch { return }
    p.waitUntilExit()
}

// MARK: - Orchestrator

enum UpdateNotifier {
    /// Checks for a newer GitHub release and notifies if found. Swallows all errors.
    static func maybeCheck(configDir: URL, localBuildVersion: String,
                           force: Bool, logger: RunLogger) async {
        do {
            try await _maybeCheck(configDir: configDir, localBuildVersion: localBuildVersion,
                                  force: force, logger: logger)
        } catch {
            logger.log("Update check failed: \(error.localizedDescription)")
        }
    }

    private static func _maybeCheck(configDir: URL, localBuildVersion: String,
                                    force: Bool, logger: RunLogger) async throws {
        let store = UpdateCheckStore(directory: configDir)
        var s = store.load()

        guard UpdateCheck.shouldCheck(lastCheck: s.lastCheck, now: Date(),
                                      interval: 86_400, force: force) else { return }

        // Force path always re-shows the banner so --check-update doesn't look broken
        // after the notify-once guard has already fired for this remote build.
        if force { s.lastNotifiedBuild = nil }

        logger.log("Update check: fetching latest release from GitHub...")

        let tag: String?
        do {
            tag = try await fetchLatestReleaseTag()
        } catch {
            logger.log("Update check network error: \(error.localizedDescription)")
            s.lastCheck = Date()
            store.save(s)
            return
        }
        s.lastCheck = Date()

        guard let tag else {
            logger.log("Update check: no releases found on GitHub yet")
            store.save(s)
            return
        }
        guard let remote = parseBuildNumber(fromTag: tag) else {
            logger.log("Update check: unrecognised tag '\(tag)'")
            store.save(s)
            return
        }
        guard let local = Int(localBuildVersion) else { store.save(s); return }

        guard UpdateCheck.shouldNotify(remoteBuild: remote, localBuild: local,
                                       lastNotifiedBuild: s.lastNotifiedBuild) else {
            logger.log("Update check: up to date (build \(local), latest is \(remote))")
            store.save(s)
            return
        }

        displayUpdateNotification(
            title: "logseq-reminders-sync update available",
            message: "Build \(remote) is available (you have \(local))."
        )
        logger.log("Update available: build \(remote) (local \(local)) — notification attempted")
        s.lastNotifiedBuild = remote
        store.save(s)
    }
}

// MARK: - Errors

private enum UpdateCheckError: Error, LocalizedError {
    case httpError(status: Int)

    var errorDescription: String? {
        switch self {
        case .httpError(let status):
            return "GitHub API returned HTTP \(status)"
        }
    }
}
