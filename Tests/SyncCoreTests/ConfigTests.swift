import Testing
import Foundation
@testable import SyncCore

// Minimal valid statusLists JSON block reused across tests.
private let statusListsJSON = """
"statusLists": {
    "Backlog":   {"id": "id-backlog",   "title": "Backlog (Logseq)"},
    "Todo":      {"id": "id-todo",      "title": "Todo (Logseq)"},
    "Doing":     {"id": "id-doing",     "title": "Doing (Logseq)"},
    "In Review": {"id": "id-inreview",  "title": "In-Review (Logseq)"},
    "Canceled":  {"id": "id-cancelled", "title": "Cancelled (Logseq)"}
}
"""

@Suite("Config")
struct ConfigTests {

    @Test("Config decodes statusLists and routing helpers work")
    func decodesStatusListsAndRoutes() throws {
        let json = """
        {
            "graph": "test",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.statusLists.count == 5)
        #expect(config.listId(forStatus: "Doing") == "id-doing")
        #expect(config.listId(forStatus: "Canceled") == "id-cancelled")
        #expect(config.listId(forStatus: "Done") == nil)
        #expect(config.status(forListId: "id-backlog") == "Backlog")
        #expect(config.status(forListId: "id-cancelled") == "Canceled")
        #expect(config.status(forListId: "unknown-id") == nil)
    }

    @Test("Config managedListIds contains all five list IDs")
    func managedListIds() throws {
        let json = """
        {
            "graph": "test",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        let ids = config.managedListIds
        #expect(ids.count == 5)
        #expect(ids.contains("id-doing"))
        #expect(ids.contains("id-cancelled"))
    }

    @Test("Config decodes legacy syncDeadlines key")
    func decodesLegacySyncDeadlines() throws {
        let json = """
        {
            "graph": "reminders-test",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "syncDeadlines": true
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncDates == true)
    }

    @Test("Config decodes new syncDates key")
    func decodesNewSyncDates() throws {
        let json = """
        {
            "graph": "my-graph",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "syncDates": true
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncDates == true)
    }

    @Test("Config defaults syncDates to false when key absent")
    func defaultsSyncDatesToFalse() throws {
        let json = """
        {
            "graph": "my-graph",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncDates == false)
    }

    @Test("Config defaults syncPriority to true when key absent")
    func defaultsSyncPriorityToTrue() throws {
        let json = """
        {
            "graph": "my-graph",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncPriority == true)
    }

    @Test("Config decodes explicit syncPriority=false")
    func decodesExplicitSyncPriority() throws {
        let json = """
        {
            "graph": "my-graph",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "syncPriority": false
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncPriority == false)
    }

    @Test("logseqCliPath round-trips through encode/decode")
    func logseqCliPathRoundTrips() throws {
        let original = Config.makeDefault(
            graph: "g",
            statusLists: ["Doing": .init(id: "id-doing", title: "Logseq Doing")],
            logseqCliPath: "/opt/homebrew/bin/logseq"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        // The hand-written Codable must persist this field, or the launchd PATH fix breaks.
        #expect(decoded.logseqCliPath == "/opt/homebrew/bin/logseq")
    }

    @Test("logseqCliPath is nil when the key is absent")
    func logseqCliPathAbsentIsNil() throws {
        let json = """
        {
            "graph": "my-graph",
            \(statusListsJSON),
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins"
        }
        """
        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.logseqCliPath == nil)
    }

    @Test("makeDefault uses canonical status keys and standard defaults")
    func makeDefaultDefaults() {
        let config = Config.makeDefault(
            graph: "g",
            statusLists: [
                "Backlog": .init(id: "b", title: "Logseq Backlog"),
                "Todo": .init(id: "t", title: "Logseq Todo")
            ],
            logseqCliPath: nil
        )
        #expect(config.listId(forStatus: "Backlog") == "b")
        #expect(config.syncDates == false)
        #expect(config.syncPriority == true)
        #expect(config.gateForceFullRunMinutes == 60)
        #expect(config.conflictPolicy == "mostRecentWins")
    }

    @Test("with(graph:) changes only the graph, preserving everything else")
    func withGraphPreservesFields() throws {
        let original = Config.makeDefault(
            graph: "old",
            statusLists: ["Doing": .init(id: "id-doing", title: "Logseq Doing")],
            logseqCliPath: "/usr/local/bin/logseq"
        )
        let switched = original.with(graph: "new")
        #expect(switched.graph == "new")
        #expect(switched.statusLists == original.statusLists)
        #expect(switched.logseqCliPath == "/usr/local/bin/logseq")
        #expect(switched.syncPriority == original.syncPriority)
        #expect(switched.gateForceFullRunMinutes == original.gateForceFullRunMinutes)
    }
}
