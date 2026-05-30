import Foundation

public struct Config: Codable {
    public struct ListEntry: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public let graph: String
    /// Map from canonical Logseq status ("Doing", "Todo", etc.) to the corresponding
    /// Reminders list. "Done" has no entry — completion is tracked by isCompleted.
    public let statusLists: [String: ListEntry]
    /// Where newly-adopted tasks (Reminders → Logseq) land on today's journal page.
    /// `nil` = top level of the journal page; a non-empty title = a named sub-block
    /// (e.g. "Inbox") that adopted tasks are nested under. An empty string decodes
    /// to `nil`. Chosen interactively in `setup`.
    public let journalInboxTitle: String?
    public let fallbackInboxPage: String
    public let conflictPolicy: String
    /// Whether to sync due dates in both directions. Replaces `syncDeadlines`.
    public let syncDates: Bool
    /// Whether to sync task priority. Defaults to true (opt-out) for legacy configs.
    public let syncPriority: Bool
    /// Smart-polling gate: force a full run if this many minutes have elapsed since
    /// the last run, regardless of change-signals. Backstop for graph-reimport tx
    /// resets and the bounded under-trigger windows. Defaults to 60.
    public let gateForceFullRunMinutes: Int
    /// Absolute path to the `logseq` CLI binary. Written by `setup` so later runs —
    /// especially the PATH-stripped launchd run — resolve it deterministically. When
    /// nil, the executable falls back to `which logseq` / common locations.
    public let logseqCliPath: String?

    /// The optional "Logseq Notes" Reminders list (id + title) for one-way note import.
    /// `nil` for configs predating this feature — when nil the notes feature is inert.
    /// Deliberately kept OUT of `statusLists`/`managedListIds`: notes must never be routed
    /// as a status or adopted as a two-way mirror task (see SyncEngine `.freshNote`).
    public let notesList: ListEntry?

    // MARK: - Construction

    public init(
        graph: String,
        statusLists: [String: ListEntry],
        journalInboxTitle: String?,
        fallbackInboxPage: String,
        conflictPolicy: String,
        syncDates: Bool,
        syncPriority: Bool,
        gateForceFullRunMinutes: Int,
        logseqCliPath: String?,
        notesList: ListEntry?
    ) {
        self.graph = graph
        self.statusLists = statusLists
        self.journalInboxTitle = journalInboxTitle
        self.fallbackInboxPage = fallbackInboxPage
        self.conflictPolicy = conflictPolicy
        self.syncDates = syncDates
        self.syncPriority = syncPriority
        self.gateForceFullRunMinutes = gateForceFullRunMinutes
        self.logseqCliPath = logseqCliPath
        self.notesList = notesList
    }

    /// Copy with a different target graph, preserving every other field. Used by
    /// `switch-graph` to flip the target without disturbing list mappings or toggles.
    public func with(graph newGraph: String) -> Config {
        Config(
            graph: newGraph,
            statusLists: statusLists,
            journalInboxTitle: journalInboxTitle,
            fallbackInboxPage: fallbackInboxPage,
            conflictPolicy: conflictPolicy,
            syncDates: syncDates,
            syncPriority: syncPriority,
            gateForceFullRunMinutes: gateForceFullRunMinutes,
            logseqCliPath: logseqCliPath,
            notesList: notesList
        )
    }

    /// The canonical Logseq statuses that each map to one managed Reminders list,
    /// in display order. "Done" is intentionally absent — completion is a flag.
    public static let managedStatuses = ["Backlog", "Todo", "Doing", "In Review", "Canceled"]

    /// A fresh config with the standard defaults. `statusLists` is keyed by canonical
    /// status name (NOT the list display titles).
    /// `notesList` has NO default (unlike `journalInboxTitle`): the only place a `nil`
    /// notes list is intentional is a caller passing `notesList: nil` explicitly. Forcing
    /// it keeps full compiler enforcement on the fresh-user setup path, which builds via
    /// `makeDefault` rather than `init`.
    public static func makeDefault(
        graph: String,
        statusLists: [String: ListEntry],
        logseqCliPath: String?,
        notesList: ListEntry?,
        journalInboxTitle: String? = nil
    ) -> Config {
        Config(
            graph: graph,
            statusLists: statusLists,
            journalInboxTitle: journalInboxTitle,
            fallbackInboxPage: "Inbox",
            conflictPolicy: "mostRecentWins",
            syncDates: true,
            syncPriority: true,
            gateForceFullRunMinutes: 60,
            logseqCliPath: logseqCliPath,
            notesList: notesList
        )
    }

    // MARK: - Status ↔ list routing (SyncCore-level, EventKit-free)

    public func listId(forStatus status: String) -> String? {
        statusLists[status]?.id
    }

    public func status(forListId listId: String) -> String? {
        statusLists.first(where: { $0.value.id == listId })?.key
    }

    /// All managed calendar identifiers (for fetch scoping). Notes list is intentionally
    /// excluded — see `notesList`.
    public var managedListIds: Set<String> {
        Set(statusLists.values.map(\.id))
    }

    /// The "Logseq Notes" list calendar identifier, or nil when the feature is unconfigured.
    public var notesListId: String? { notesList?.id }

    // MARK: - Static

    public static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".logseq-reminders-sync")
    }()

    public static func load() throws -> Config {
        let url = configDir.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Atomically write this config to `~/.logseq-reminders-sync/config.json`,
    /// pretty-printed with sorted keys (creating the directory if needed).
    public func save() throws {
        try FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let url = Self.configDir.appendingPathComponent("config.json")
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Codable (backward-compat: legacy single-list keys decode but don't populate statusLists)

    private enum CodingKeys: String, CodingKey {
        case graph
        case statusLists
        case journalInboxTitle, fallbackInboxPage, conflictPolicy
        case syncDates
        case syncPriority
        case gateForceFullRunMinutes
        case logseqCliPath
        case notesList
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case syncDeadlines
        // Accepted for backward-compat parse (silently ignored — user must migrate to statusLists)
        case remindersListId, remindersListTitle, filterQueryFile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graph             = try c.decode(String.self, forKey: .graph)
        statusLists       = try c.decode([String: ListEntry].self, forKey: .statusLists)
        let rawInbox = try c.decodeIfPresent(String.self, forKey: .journalInboxTitle)
        journalInboxTitle = (rawInbox?.isEmpty == true) ? nil : rawInbox
        fallbackInboxPage = try c.decode(String.self, forKey: .fallbackInboxPage)
        conflictPolicy    = try c.decode(String.self, forKey: .conflictPolicy)
        // Accept both "syncDates" (new) and "syncDeadlines" (legacy key)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .syncDates) {
            syncDates = v
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            syncDates = (try? legacy.decode(Bool.self, forKey: .syncDeadlines)) ?? true
        }
        syncPriority = (try? c.decodeIfPresent(Bool.self, forKey: .syncPriority)) ?? true
        gateForceFullRunMinutes = (try? c.decodeIfPresent(Int.self, forKey: .gateForceFullRunMinutes)) ?? 60
        logseqCliPath = try c.decodeIfPresent(String.self, forKey: .logseqCliPath)
        notesList = try c.decodeIfPresent(ListEntry.self, forKey: .notesList)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(graph,             forKey: .graph)
        try c.encode(statusLists,       forKey: .statusLists)
        try c.encodeIfPresent(journalInboxTitle, forKey: .journalInboxTitle)
        try c.encode(fallbackInboxPage, forKey: .fallbackInboxPage)
        try c.encode(conflictPolicy,    forKey: .conflictPolicy)
        try c.encode(syncDates,         forKey: .syncDates)
        try c.encode(syncPriority,      forKey: .syncPriority)
        try c.encode(gateForceFullRunMinutes, forKey: .gateForceFullRunMinutes)
        try c.encodeIfPresent(logseqCliPath, forKey: .logseqCliPath)
        try c.encodeIfPresent(notesList, forKey: .notesList)
    }
}
