import Foundation
import SyncCore

@main
struct App {
    // BUILD 36 (fix silent try? swallowing on un-complete and title/notes sync writes)
    static let buildVersion = "36"
    static let appVersion = "0.1.0"

    static func main() async throws {
        let args = CommandLine.arguments.dropFirst()

        if args.contains("--version") || args.contains("-v") {
            print("logseq-reminders-sync \(Self.appVersion) (build \(Self.buildVersion))")
            return
        }

        if args.contains("--help") || args.contains("-h") {
            printHelp()
            return
        }

        do {
            // `setup` runs WITHOUT an existing config — it creates one. Handle it before
            // Config.load() so a clean machine doesn't fail.
            if args.contains("setup") || args.contains("--setup") {
                try await Setup.run()
                return
            }

            let config = try Config.load()

            if args.contains("switch-graph") || args.contains("--switch-graph") {
                try await Setup.switchGraph(config: config)
                return
            }

            if args.contains("--dump-reminders") {
                try await dumpReminders(config: config)
                return
            }

            if args.contains("--dump-tasks") {
                try await dumpTasks(config: config)
                return
            }

            if args.contains("--backfill-links") {
                try await backfillLinks(config: config)
                return
            }

            // Default / --once: run a single sync
            try await runOnce(config: config, force: args.contains("--force"))
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Logseq CLI path resolution

    /// Resolve the absolute path to the `logseq` CLI, config-first so the PATH-stripped
    /// launchd run is deterministic: `config.logseqCliPath` → `which logseq` → common
    /// install locations. Throws if none resolve.
    static func resolveCliPath(config: Config?) throws -> String {
        let fm = FileManager.default
        if let p = config?.logseqCliPath, !p.isEmpty, fm.isExecutableFile(atPath: p) {
            return p
        }
        if let p = which("logseq") { return p }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/logseq",
            "/opt/homebrew/bin/logseq",
            "/usr/local/bin/logseq"
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        throw CliError.logseqNotFound
    }

    /// Locate an executable on PATH via `/usr/bin/which`. Returns nil under a stripped
    /// environment (e.g. launchd) — callers resolve from config first for that reason.
    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
            FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    // MARK: - Sync

    static func runOnce(config: Config, force: Bool = false) async throws {
        let fm = FileManager.default
        let configDir = Config.configDir

        // Ensure directories exist
        let logDir = configDir.appendingPathComponent("log")
        try? fm.createDirectory(at: logDir, withIntermediateDirectories: true)

        let logger = RunLogger(logDirectory: logDir)
        logger.log("logseq-reminders-sync build \(buildVersion)")

        // Acquire lockfile
        let lockURL = configDir.appendingPathComponent("lock")
        let lock = Lockfile(url: lockURL)
        try lock.acquire()
        defer { lock.release() }

        // Set up stores
        let stateStore = StateStore(directory: configDir)
        let remindersStore = RemindersStore()

        // Authorize and resolve Reminders lists
        logger.log("Authorizing Reminders access...")
        try await remindersStore.authorize()
        logger.log("Resolving Reminders lists...")
        try await remindersStore.resolveCalendars(config: config)

        // Construct the Logseq client (struct init — no I/O). bootstrap() is deferred
        // to the run path so the gate's cheap probe doesn't pay ~7 CLI round-trips.
        let cliPath = try resolveCliPath(config: config)
        var logseqClient = LogseqClient(cliPath: cliPath, graph: config.graph, logger: logger)

        // ── Smart-polling gate ────────────────────────────────────────────────
        // Skip the full pass when neither side changed since the last run. Any
        // probe failure falls through to a full sync (over-trigger, never under).
        let state = stateStore.load()
        if force {
            logger.log("--force: bypassing change gate")
        } else {
            do {
                let tx = try await logseqClient.fetchMaxTx()
                let sig = try await remindersStore.changeSignal()
                let current = ChangeSignals(
                    logseqMaxTx: tx,
                    remindersListCounts: sig.listCounts,
                    remindersMaxModifiedMs: sig.maxModifiedMs
                )
                let decision = SyncGate.decision(
                    cached: state.signals,
                    current: current,
                    lastRun: state.lastRunDate,
                    now: Date(),
                    forceAfter: TimeInterval(config.gateForceFullRunMinutes * 60)
                )
                if decision == .skip {
                    logger.log(
                        "No changes since last run (logseq tx=\(tx), reminders=\(sig.listCounts) mod=\(sig.maxModifiedMs)) — skipping"
                    )
                    return
                }
            } catch {
                logger.log("Gate probe failed (\(error.localizedDescription)) — running full sync")
            }
        }

        // Bootstrap Logseq client (run path only)
        logger.log("Bootstrapping Logseq client for graph '\(config.graph)'...")
        try await logseqClient.bootstrap()

        // Run engine
        var engine = SyncEngine(
            logseq: logseqClient,
            reminders: remindersStore,
            stateStore: stateStore,
            config: config,
            logger: logger
        )
        try await engine.run()

        // ── Post-write baseline ───────────────────────────────────────────────
        // Recompute signals AFTER the engine's writes so the gate doesn't read our
        // own writes as a change next poll. Fresh-load (the engine just saved its
        // own state) and update only the three signal fields to avoid clobbering it.
        do {
            let tx = try await logseqClient.fetchMaxTx()
            let sig = try await remindersStore.changeSignal()
            var fresh = stateStore.load()
            fresh.logseqMaxTx = tx
            fresh.remindersListCounts = sig.listCounts
            fresh.remindersMaxModifiedMs = sig.maxModifiedMs
            stateStore.save(fresh)
        } catch {
            logger.log(
                "Post-run signal capture failed (\(error.localizedDescription)) — " +
                "gate cache not updated; next run will be a full sync"
            )
        }
    }

    // MARK: - Backfill

    /// One-shot: write the Logseq backlink into the URL field of every already-paired
    /// mirror reminder. For reminders created before build 18 (the create path and
    /// reindex guard keep newer ones current). Writes to EventKit, so it acquires the
    /// lockfile and authorizes — unlike the read-only `--dump-*` flags. Idempotent:
    /// re-running touches nothing already correct.
    static func backfillLinks(config: Config) async throws {
        let configDir = Config.configDir

        // Acquire the lockfile so this can't race a concurrent sync's EventKit writes.
        let lockURL = configDir.appendingPathComponent("lock")
        let lock = Lockfile(url: lockURL)
        try lock.acquire()
        defer { lock.release() }

        let remindersStore = RemindersStore()
        try await remindersStore.authorize()
        try await remindersStore.resolveCalendars(config: config)

        let state = StateStore(directory: configDir).load()
        print("Backfilling Logseq backlinks for \(state.pairs.count) mirrored reminder(s)…")

        var written = 0, alreadyCorrect = 0, failed = 0, missing = 0
        for pair in state.pairs {
            guard let link = Mapper.logseqDeepLink(graph: config.graph, blockUUID: pair.logseqUUID) else {
                print("  WARN: could not build backlink for \(pair.logseqUUID.prefix(8))…")
                missing += 1
                continue
            }
            switch await remindersStore.setURLAttachment(localId: pair.reminderLocalId, url: link) {
            case .written:       written += 1
            case .alreadyCorrect: alreadyCorrect += 1
            case .notFound:      missing += 1
            case .failed:
                failed += 1
                print(
                    "  WARN: backlink not written for \(pair.logseqUUID.prefix(8))…" +
                    " — REMURLAttachment save returned failure. See ReminderKitBridge.m"
                )
            }
        }
        print("Done. \(written) written, \(alreadyCorrect) already current, \(failed) failed, \(missing) missing.")
    }

    // MARK: - Diagnostics

    static func dumpReminders(config: Config) async throws {
        let remindersStore = RemindersStore()
        try await remindersStore.authorize()
        try await remindersStore.resolveCalendars(config: config)

        let managed = await remindersStore.managedCalendarTitles()
        let managedIds = Set(config.managedListIds)
        let allLists = await remindersStore.allCalendars()
        print("All Reminders lists:")
        for list in allLists {
            let marker = managedIds.contains(list.calendarIdentifier) ? " ← managed" : ""
            print("  \(list.title)\(marker)")
        }
        print("\nManaged status lists:")
        for (status, title) in managed.sorted(by: { $0.key < $1.key }) {
            print("  \(status) → \(title)")
        }

        let incomplete = try await remindersStore.fetchIncomplete()
        print("\nIncomplete reminders (\(incomplete.count)):")
        for r in incomplete {
            print("  [\(r.localId.prefix(8))…] \(r.title)")
            if let notes = r.notes, !notes.isEmpty {
                print("    notes: \(notes.prefix(80))")
            }
            print("    priority: \(formatReminderPriority(r.priority))")
        }

        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let completed = try await remindersStore.fetchCompleted(since: since)
        print("\nCompleted (last 7 days) (\(completed.count)):")
        for r in completed {
            print("  [\(r.localId.prefix(8))…] \(r.title)")
            print("    priority: \(formatReminderPriority(r.priority))")
        }
    }

    static func dumpTasks(config: Config) async throws {
        let cliPath = try resolveCliPath(config: config)
        var client = LogseqClient(cliPath: cliPath, graph: config.graph)
        try await client.bootstrap()
        print("Property idents:")
        print("  reminder-id          → \(client.propertyIdents?.reminderId ?? "(none)")")
        print("  captured-reminder-id → \(client.propertyIdents?.capturedReminderId ?? "(none)")")

        let tasks = try await client.fetchPrioritizedTasks()
        print("\nPrioritized tasks (Urgent/High/Medium) (\(tasks.count)):")
        for t in tasks {
            print("  [\(t.uuid.prefix(8))…] \(t.title)")
            if let s = t.status { print("    status: \(s)") } else { print("    status: (none)") }
            print("    priority: \(t.priority?.rawValue ?? "(none)")")
        }
    }

    /// Apple Reminders int → human label. Mirrors the bucketed reverse mapping
    /// the engine uses, plus "none" for 0.
    private static func formatReminderPriority(_ priority: Int) -> String {
        switch priority {
        case 0:     return "0 (none)"
        case 1...4: return "\(priority) (High)"
        case 5...8: return "\(priority) (Medium)"
        case 9:     return "9 (Low)"
        default:    return "\(priority) (out of range)"
        }
    }

    // MARK: - Help

    static func printHelp() {
        print("""
        logseq-reminders-sync \(Self.appVersion)

        Usage: logseq-reminders-sync [command|options]

        Commands:
          setup              Interactive first-run setup: request Reminders access,
                             pick a graph, create the 5 lists, write config, and
                             optionally install the background sync agent
          switch-graph       Point the tool at a different Logseq graph: empty the 5
                             lists, strip sync markers from the old graph, reset state

        Options:
          --version, -v      Print version and exit
          --help, -h         Print this help and exit
          --once             Run a single sync and exit (default)
          --force            Bypass the change gate and run a full sync pass
          --dump-reminders   List reminders in the configured lists (diagnostic)
          --dump-tasks       List prioritized tasks in the configured graph (diagnostic)
          --backfill-links   Write the Logseq backlink into existing mirror
                             reminders' URL field (one-shot; writes, acquires lock)

        Config: ~/.logseq-reminders-sync/config.json
        State:  ~/.logseq-reminders-sync/state.json
        Logs:   ~/.logseq-reminders-sync/log/
        """)
    }
}

// MARK: - Errors

enum CliError: Error, LocalizedError {
    case logseqNotFound

    var errorDescription: String? {
        switch self {
        case .logseqNotFound:
            return "Could not find the `logseq` CLI. Install it, ensure it's on your PATH, " +
                   "or set \"logseqCliPath\" to its absolute path in ~/.logseq-reminders-sync/config.json."
        }
    }
}
