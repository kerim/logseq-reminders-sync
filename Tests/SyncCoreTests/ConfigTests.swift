import Testing
import Foundation
@testable import SyncCore

@Suite("Config")
struct ConfigTests {
    @Test("Config decodes legacy syncDeadlines key")
    func decodesLegacySyncDeadlines() throws {
        let json = """
        {
            "graph": "reminders-test",
            "remindersListId": "list-id-123",
            "remindersListTitle": "Logseq",
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "filterQueryFile": "filter.datalog",
            "syncDeadlines": true
        }
        """

        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.graph == "reminders-test")
        #expect(config.remindersListTitle == "Logseq")
        #expect(config.syncDates == true)
    }

    @Test("Config decodes new syncDates key")
    func decodesNewSyncDates() throws {
        let json = """
        {
            "graph": "my-graph",
            "remindersListId": "",
            "remindersListTitle": "Tasks",
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "filterQueryFile": "",
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
            "remindersListId": "",
            "remindersListTitle": "Tasks",
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "filterQueryFile": ""
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
            "remindersListId": "",
            "remindersListTitle": "Tasks",
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "filterQueryFile": ""
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
            "remindersListId": "",
            "remindersListTitle": "Tasks",
            "journalInboxTitle": "📥 Inbox",
            "fallbackInboxPage": "Inbox",
            "conflictPolicy": "mostRecentWins",
            "filterQueryFile": "",
            "syncPriority": false
        }
        """

        let config = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        #expect(config.syncPriority == false)
    }
}
