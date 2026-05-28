import Foundation
import SyncCore

@main
struct App {
    // BUILD 16 (local-tz date conversion + midnight = date-only heuristic)
    static let buildVersion = "16"
    static let appVersion = "0.1.0"

    static let cliPath = "/Users/niyaro/.local/bin/logseq"

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
            let config = try Config.load()

            if args.contains("--dump-reminders") {
                try await dumpReminders(config: config)
                return
            }

            if args.contains("--dump-tasks") {
                try await dumpTasks(config: config)
                return
            }

            // Default / --once: run a single sync
            try await runOnce(config: config)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - Sync

    static func runOnce(config: Config) async throws {
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

        // Authorize Reminders
        logger.log("Authorizing Reminders access...")
        try await remindersStore.authorize()
        logger.log("Resolving Reminders list '\(config.remindersListTitle)'...")
        _ = try await remindersStore.resolveCalendar(
            listId: config.remindersListId,
            listTitle: config.remindersListTitle
        )

        // Bootstrap Logseq client
        logger.log("Bootstrapping Logseq client for graph '\(config.graph)'...")
        var logseqClient = LogseqClient(cliPath: cliPath, graph: config.graph)
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
    }

    // MARK: - Diagnostics

    static func dumpReminders(config: Config) async throws {
        let remindersStore = RemindersStore()
        try await remindersStore.authorize()
        let resolvedId = try await remindersStore.resolveCalendar(
            listId: config.remindersListId,
            listTitle: config.remindersListTitle
        )

        let allLists = await remindersStore.allCalendars()
        print("All Reminders lists:")
        for list in allLists {
            let marker = list.calendarIdentifier == resolvedId ? " ← configured" : ""
            print("  \(list.title)\(marker)")
        }
        print("\nMonitoring: '\(config.remindersListTitle)'")

        let incomplete = try await remindersStore.fetchIncomplete()
        print("\nIncomplete reminders (\(incomplete.count)):")
        for r in incomplete {
            print("  [\(r.localId.prefix(8))…] \(r.title)")
            if let notes = r.notes, !notes.isEmpty {
                print("    notes: \(notes.prefix(80))")
            }
        }

        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let completed = try await remindersStore.fetchCompleted(since: since)
        print("\nCompleted (last 7 days) (\(completed.count)):")
        for r in completed {
            print("  [\(r.localId.prefix(8))…] \(r.title)")
        }
    }

    static func dumpTasks(config: Config) async throws {
        var client = LogseqClient(cliPath: cliPath, graph: config.graph)
        try await client.bootstrap()
        print("Property idents:")
        print("  reminder-id          → \(client.propertyIdents?.reminderId ?? "(none)")")
        print("  captured-reminder-id → \(client.propertyIdents?.capturedReminderId ?? "(none)")")

        let tasks = try await client.fetchDoingTasks()
        print("\nDoing tasks (\(tasks.count)):")
        for t in tasks {
            print("  [\(t.uuid.prefix(8))…] \(t.title)")
            if let s = t.status { print("    status: \(s)") }
        }
    }

    // MARK: - Help

    static func printHelp() {
        print("""
        logseq-reminders-sync \(Self.appVersion)

        Usage: logseq-reminders-sync [options]

        Options:
          --version, -v      Print version and exit
          --help, -h         Print this help and exit
          --once             Run a single sync and exit (default)
          --dump-reminders   List reminders in the configured list (diagnostic)
          --dump-tasks       List Doing tasks in the configured graph (diagnostic)

        Config: ~/.logseq-reminders-sync/config.json
        State:  ~/.logseq-reminders-sync/state.json
        Logs:   ~/.logseq-reminders-sync/log/
        """)
    }
}
