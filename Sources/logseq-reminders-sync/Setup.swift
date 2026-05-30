import Foundation
import SyncCore

/// Interactive onboarding (`setup`) and graph switching (`switch-graph`). Both mutate
/// live Reminders data and config, so they acquire the lockfile and coordinate with the
/// launchd agent. All EventKit work goes through the `RemindersStore` actor.
enum Setup {
    /// Standard list display titles, keyed by canonical Logseq status.
    static let listTitles: [String: String] = [
        "Backlog": "Logseq Backlog",
        "Todo": "Logseq Todo",
        "Doing": "Logseq Doing",
        "In Review": "Logseq In Review",
        "Canceled": "Logseq Canceled"
    ]

    /// Display title for the one-way notes-import list. NOT a status list — reminders
    /// here are imported into Logseq as plain notes (see SyncEngine `.freshNote`).
    static let notesListTitle = "Logseq Notes"

    // MARK: - First-run setup

    static func run() async throws {
        // 1. Ensure config dir, then acquire the lock (write target must exist first),
        //    then bootout any existing agent so it can't fire mid-setup.
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let lock = Lockfile(url: Config.configDir.appendingPathComponent("lock"))
        try lock.acquire()
        defer { lock.release() }

        // Bootout any existing agent so it can't fire mid-setup. Restore it on every exit
        // path (cancel OR thrown error) unless a fresh agent was installed — otherwise a
        // mid-setup failure would silently leave background sync stopped.
        let hadAgent = LaunchdAgent.isInstalled()
        if hadAgent { LaunchdAgent.bootout() }
        var installedNewAgent = false
        defer { if hadAgent && !installedNewAgent { LaunchdAgent.bootstrap() } }

        print("logseq-reminders-sync setup\n")

        // 2. Reminders access (interactive — the TCC prompt must appear here).
        print("Requesting Reminders access…")
        let store = RemindersStore()
        try await store.authorize()
        print("  ✓ Reminders access granted.\n")

        // 3. Resolve the logseq CLI (absolute), prompting if not found.
        let cliPath = try resolveCli()
        print("Using logseq CLI at: \(cliPath)\n")

        // 4. Pick a graph.
        let lister = LogseqClient(cliPath: cliPath, graph: "")
        let graphs = try await lister.listGraphs()
        guard !graphs.isEmpty else { throw SetupError.noGraphs }
        guard let idx = Prompt.choose("Which Logseq graph should sync with Reminders?", options: graphs) else {
            print("Cancelled — no changes made.")
            return   // defer restores the agent
        }
        let graph = graphs[idx]
        print("  ✓ Graph: \(graph)\n")

        // Guard: re-running setup against a DIFFERENT graph would rewrite config without
        // emptying the lists or stripping the old graph's sync markers — the next sync
        // would then silently delete the old graph's reminders. Redirect to switch-graph,
        // which does the full clean. BUT only when the old graph still exists: if it's
        // gone (deleted in Logseq), there's nothing to clean and switch-graph can't run,
        // so allow a fresh setup instead of dead-ending.
        let existing = try? Config.load()
        if let existing, existing.graph != graph, graphs.contains(existing.graph) {
            print("""
            This tool is already set up for graph '\(existing.graph)'.
            To move it to '\(graph)', use:
                logseq-reminders-sync switch-graph
            (That safely empties the lists and clears the old graph's sync markers first.)
            """)
            return   // defer restores the agent
        }

        // 5. Create (or reuse) the five lists, keyed by canonical status.
        print("Creating Reminders lists…")
        var statusLists: [String: Config.ListEntry] = [:]
        for status in Config.managedStatuses {
            let title = listTitles[status] ?? "Logseq \(status)"
            let id = try await store.findOrCreateList(title: title)
            statusLists[status] = Config.ListEntry(id: id, title: title)
            print("  ✓ \(title)")
        }
        // The sixth list: one-way notes import (reused by title, like the status lists).
        let notesId = try await store.findOrCreateList(title: notesListTitle)
        let notesEntry = Config.ListEntry(id: notesId, title: notesListTitle)
        print("  ✓ \(notesListTitle)")
        print("")

        // 6. Write config (preserving existing scalar settings on a same-graph re-run).
        let newConfig: Config
        if let existing {
            guard Prompt.confirm(
                "A config already exists. Set it up for '\(graph)' now? " +
                "(your sync toggles are preserved)", defaultYes: true) else {
                print("Cancelled — no changes made.")
                return   // defer restores the agent
            }
            let inboxTitle = promptInboxDestination(current: existing.journalInboxTitle)
            newConfig = Config(
                graph: graph,
                statusLists: statusLists,
                journalInboxTitle: inboxTitle,
                fallbackInboxPage: existing.fallbackInboxPage,
                conflictPolicy: existing.conflictPolicy,
                syncDates: existing.syncDates,
                syncPriority: existing.syncPriority,
                gateForceFullRunMinutes: existing.gateForceFullRunMinutes,
                logseqCliPath: cliPath,
                notesList: notesEntry
            )
        } else {
            let inboxTitle = promptInboxDestination(current: nil)
            newConfig = Config.makeDefault(
                graph: graph, statusLists: statusLists, logseqCliPath: cliPath,
                notesList: notesEntry,
                journalInboxTitle: inboxTitle)
        }
        try newConfig.save()
        print("  ✓ Wrote \(Config.configDir.appendingPathComponent("config.json").path)\n")

        // 7. Offer the background sync agent.
        if Prompt.confirm("Run sync automatically in the background?", defaultYes: true) {
            let entered = Prompt.line("  Sync interval in minutes [15]: ")?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let minutes = max(1, Int(entered) ?? 15)
            let binaryPath = installedBinaryPath()
            try LaunchdAgent.install(binaryPath: binaryPath, intervalSeconds: minutes * 60)
            installedNewAgent = true
            print("  ✓ Background sync installed (every \(minutes) min).\n")
        } else if hadAgent {
            print("  Keeping the existing background agent.\n")   // defer re-bootstraps it
        }

        // 8. Summary.
        print("""
        Setup complete.
          • Run a sync now:        logseq-reminders-sync --once
          • Switch graphs later:   logseq-reminders-sync switch-graph
          • Inspect config/state:  ~/.logseq-reminders-sync/
        """)
    }

    // MARK: - Graph switching (full clean)

    static func switchGraph(config: Config) async throws {
        // 1. Lock FIRST (fail fast if a run holds it), then bootout the agent.
        try FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        let lock = Lockfile(url: Config.configDir.appendingPathComponent("lock"))
        try lock.acquire()
        defer { lock.release() }

        let hadAgent = LaunchdAgent.isInstalled()
        if hadAgent { LaunchdAgent.bootout() }

        let oldGraph = config.graph
        var destructionBegan = false

        do {
            // 2. Authorize; resolve CLI. Note: we deliberately do NOT call
            // resolveCalendars — it hard-fails if the user already deleted the managed
            // lists, and switch-graph's job is to empty whatever lists still exist
            // (emptyManagedLists / countRemaining read the store directly).
            let store = RemindersStore()
            try await store.authorize()
            let cliPath = try App.resolveCliPath(config: config)

            // 3. Pick + validate the new graph (nothing destroyed yet).
            let lister = LogseqClient(cliPath: cliPath, graph: oldGraph)
            let graphs = try await lister.listGraphs()
            guard !graphs.isEmpty else { throw SetupError.noGraphs }
            guard let idx = Prompt.choose(
                "Switch syncing to which graph? (current: \(oldGraph))", options: graphs) else {
                print("Cancelled — no changes made.")
                if hadAgent { LaunchdAgent.bootstrap() }
                return
            }
            let newGraph = graphs[idx]
            guard newGraph != oldGraph else {
                print("Already syncing '\(oldGraph)' — nothing to switch.")
                if hadAgent { LaunchdAgent.bootstrap() }
                return
            }

            // 4. Confirm. EOF / anything but y/yes aborts — nothing destroyed yet.
            guard Prompt.confirm("""
                This will DELETE every reminder in the managed Logseq lists (the five status
                lists and "\(notesListTitle)"), remove sync markers from graph '\(oldGraph)',
                reset sync state, and switch to '\(newGraph)'. Continue?
                """) else {
                print("Aborted — no changes made.")
                if hadAgent { LaunchdAgent.bootstrap() }
                return
            }

            // 5. Empty the managed lists (incomplete + completed, unbounded).
            destructionBegan = true
            print("Emptying the managed Logseq lists…")
            try await store.emptyManagedLists(config: config)

            // 6. Verify the empty before flipping config.
            let remaining = try await store.countRemaining(inManagedLists: config)
            guard remaining == 0 else { throw SetupError.emptyIncomplete(remaining) }

            // 7. Strip sync markers from the OLD graph (idents resolved against it).
            print("Removing sync markers from '\(oldGraph)'…")
            var oldClient = LogseqClient(cliPath: cliPath, graph: oldGraph)
            try await oldClient.bootstrap()
            let cleared = try await oldClient.clearSyncProperties()

            // 8. Reset state (rebuildable cache; nothing to rebuild from now). A real
            // removal error must abort BEFORE the config flip — don't swallow it, or stale
            // pairs would survive the switch and drive silent reminder deletion next run.
            let stateURL = Config.configDir.appendingPathComponent("state.json")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.removeItem(at: stateURL)
            }

            // 9. Write the new graph LAST (safer crash order).
            try config.with(graph: newGraph).save()

            print("""

            Switched to '\(newGraph)'.
              • Emptied the managed Logseq lists (5 status + notes)
              • Cleared \(cleared) sync marker(s) from '\(oldGraph)'
              • Reset sync state
            """)
            if hadAgent {
                LaunchdAgent.bootstrap()
                print("  Background sync re-armed.")
            } else {
                print("  Run `logseq-reminders-sync --once` to populate the new graph's lists.")
            }
        } catch {
            if destructionBegan {
                // Leave the agent DOWN so a scheduled run can't repopulate a half-cleaned
                // graph and hide the failure.
                fputs("\nswitch-graph FAILED after changes began: \(error.localizedDescription)\n", stderr)
                fputs("Background sync has been left STOPPED. Re-run `logseq-reminders-sync " +
                      "switch-graph` to finish; it will be restarted on success.\n", stderr)
            } else if hadAgent {
                LaunchdAgent.bootstrap()   // nothing destroyed — restore
            }
            throw error
        }
    }

    // MARK: - CLI resolution with fallback prompt

    /// Absolute path of the running binary, for the launchd plist. The argv[0] fallback
    /// is standardized so a relative invocation never lands in the plist.
    private static func installedBinaryPath() -> String {
        if let p = Bundle.main.executableURL?.path { return p }
        return URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    }

    private static func resolveCli() throws -> String {
        if let resolved = try? App.resolveCliPath(config: nil) { return resolved }
        guard let entered = Prompt.line("Path to the `logseq` CLI binary: ")?
            .trimmingCharacters(in: .whitespaces), !entered.isEmpty,
            FileManager.default.isExecutableFile(atPath: entered) else {
            throw CliError.logseqNotFound
        }
        return entered
    }

    // MARK: - Inbox destination

    /// Prompt the user for where newly-adopted tasks should land on the journal page.
    /// `current` is the existing setting (nil = top-level) used to pre-fill on re-runs.
    /// Returns nil for top-level placement or a non-empty title for a named sub-block.
    private static func promptInboxDestination(current: String?) -> String? {
        let useNamed = Prompt.confirm(
            "Place newly-adopted tasks under a named sub-block on the journal page?" +
            " (No = add them at the top level of the day's journal)",
            defaultYes: current != nil)
        guard useNamed else { return nil }
        let def = current ?? "Inbox"
        let entered = Prompt.line("  Sub-block title [\(def)]: ")?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return entered.isEmpty ? def : entered
    }
}

// MARK: - Errors

enum SetupError: Error, LocalizedError {
    case noGraphs
    case emptyIncomplete(Int)

    var errorDescription: String? {
        switch self {
        case .noGraphs:
            return "No Logseq graphs found. Create one in Logseq first, then re-run."
        case .emptyIncomplete(let n):
            return "Could not fully empty the managed lists (\(n) reminder(s) remain). " +
                   "Config left on the old graph; nothing was switched. Re-run to retry."
        }
    }
}

// MARK: - Terminal prompts

enum Prompt {
    /// Print a message (no newline) and read one line. nil on EOF.
    static func line(_ message: String) -> String? {
        print(message, terminator: "")
        return readLine()
    }

    /// Yes/no confirm. Anything but y/yes — including EOF / empty-when-not-defaultYes —
    /// is treated as "no" so non-interactive invocations never destroy silently.
    static func confirm(_ message: String, defaultYes: Bool = false) -> Bool {
        let suffix = defaultYes ? " [Y/n] " : " [y/N] "
        print(message + suffix, terminator: "")
        guard let raw = readLine() else { return false }   // EOF → no
        let answer = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if answer.isEmpty { return defaultYes }
        return answer == "y" || answer == "yes"
    }

    /// Numbered picker. Returns the chosen index, or nil on invalid input / EOF / cancel.
    static func choose(_ message: String, options: [String]) -> Int? {
        guard !options.isEmpty else { return nil }
        print(message)
        for (i, opt) in options.enumerated() {
            print("  \(i + 1). \(opt)")
        }
        print("Enter a number (1-\(options.count)): ", terminator: "")
        guard let raw = readLine()?.trimmingCharacters(in: .whitespaces),
              let n = Int(raw), n >= 1, n <= options.count else {
            return nil
        }
        return n - 1
    }
}
