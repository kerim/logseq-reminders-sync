import Foundation

public struct Config: Codable {
    public struct ListEntry: Codable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }

    public let graph: String
    /// Map from canonical Logseq status ("Doing", "Todo", etc.) to the corresponding
    /// Reminders list. "Done" has no entry — completion is tracked by isCompleted.
    public let statusLists: [String: ListEntry]
    public let journalInboxTitle: String
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

    // MARK: - Status ↔ list routing (SyncCore-level, EventKit-free)

    public func listId(forStatus status: String) -> String? {
        statusLists[status]?.id
    }

    public func status(forListId listId: String) -> String? {
        statusLists.first(where: { $0.value.id == listId })?.key
    }

    /// All managed calendar identifiers (for fetch scoping).
    public var managedListIds: Set<String> {
        Set(statusLists.values.map(\.id))
    }

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

    // MARK: - Codable (backward-compat: legacy single-list keys decode but don't populate statusLists)

    private enum CodingKeys: String, CodingKey {
        case graph
        case statusLists
        case journalInboxTitle, fallbackInboxPage, conflictPolicy
        case syncDates
        case syncPriority
        case gateForceFullRunMinutes
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
        journalInboxTitle = try c.decode(String.self, forKey: .journalInboxTitle)
        fallbackInboxPage = try c.decode(String.self, forKey: .fallbackInboxPage)
        conflictPolicy    = try c.decode(String.self, forKey: .conflictPolicy)
        // Accept both "syncDates" (new) and "syncDeadlines" (legacy key)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .syncDates) {
            syncDates = v
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            syncDates = (try? legacy.decode(Bool.self, forKey: .syncDeadlines)) ?? false
        }
        syncPriority = (try? c.decodeIfPresent(Bool.self, forKey: .syncPriority)) ?? true
        gateForceFullRunMinutes = (try? c.decodeIfPresent(Int.self, forKey: .gateForceFullRunMinutes)) ?? 60
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(graph,             forKey: .graph)
        try c.encode(statusLists,       forKey: .statusLists)
        try c.encode(journalInboxTitle, forKey: .journalInboxTitle)
        try c.encode(fallbackInboxPage, forKey: .fallbackInboxPage)
        try c.encode(conflictPolicy,    forKey: .conflictPolicy)
        try c.encode(syncDates,         forKey: .syncDates)
        try c.encode(syncPriority,      forKey: .syncPriority)
        try c.encode(gateForceFullRunMinutes, forKey: .gateForceFullRunMinutes)
    }
}
