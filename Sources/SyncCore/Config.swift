import Foundation

public struct Config: Codable {
    public let graph: String
    public let remindersListId: String
    public let remindersListTitle: String
    public let journalInboxTitle: String
    public let fallbackInboxPage: String
    public let conflictPolicy: String
    public let filterQueryFile: String
    /// Whether to sync due dates in both directions. Replaces `syncDeadlines`.
    public let syncDates: Bool

    public static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".logseq-reminders-sync")
    }()

    public static func load() throws -> Config {
        let url = configDir.appendingPathComponent("config.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    // MARK: - Codable (backward-compat: accepts "syncDeadlines" as alias for "syncDates")

    private enum CodingKeys: String, CodingKey {
        case graph, remindersListId, remindersListTitle
        case journalInboxTitle, fallbackInboxPage, conflictPolicy, filterQueryFile
        case syncDates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graph               = try c.decode(String.self, forKey: .graph)
        remindersListId     = try c.decode(String.self, forKey: .remindersListId)
        remindersListTitle  = try c.decode(String.self, forKey: .remindersListTitle)
        journalInboxTitle   = try c.decode(String.self, forKey: .journalInboxTitle)
        fallbackInboxPage   = try c.decode(String.self, forKey: .fallbackInboxPage)
        conflictPolicy      = try c.decode(String.self, forKey: .conflictPolicy)
        filterQueryFile     = try c.decode(String.self, forKey: .filterQueryFile)
        // Accept both "syncDates" (new) and "syncDeadlines" (legacy key)
        if let v = try c.decodeIfPresent(Bool.self, forKey: .syncDates) {
            syncDates = v
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            syncDates = (try? legacy.decode(Bool.self, forKey: .syncDeadlines)) ?? false
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(graph,              forKey: .graph)
        try c.encode(remindersListId,    forKey: .remindersListId)
        try c.encode(remindersListTitle, forKey: .remindersListTitle)
        try c.encode(journalInboxTitle,  forKey: .journalInboxTitle)
        try c.encode(fallbackInboxPage,  forKey: .fallbackInboxPage)
        try c.encode(conflictPolicy,     forKey: .conflictPolicy)
        try c.encode(filterQueryFile,    forKey: .filterQueryFile)
        try c.encode(syncDates,          forKey: .syncDates)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case syncDeadlines
    }
}
