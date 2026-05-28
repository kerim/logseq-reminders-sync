import Testing
import Foundation
@testable import SyncCore

@Suite("SyncPairCodable")
struct SyncPairCodableTests {

    private let legacyJSON = """
    {
        "logseqUUID": "abc-123",
        "reminderLocalId": "local-1",
        "reminderExtId": "ext-1",
        "lastStatus": "Doing",
        "lastOpenStatus": "Doing",
        "lastCompleted": false,
        "lastLogseqUpdated": 1748390400000,
        "lastReminderMod": null,
        "lastTitle": "Test task",
        "lastNotesHash": "deadbeef"
    }
    """.data(using: .utf8)!

    @Test("Decodes pre-upgrade state.json without new fields")
    func decodesLegacyPair() throws {
        let pair = try JSONDecoder().decode(SyncPair.self, from: legacyJSON)
        #expect(pair.logseqUUID == "abc-123")
        #expect(pair.lastDueDateMs == nil)
        #expect(pair.lastDueSource == nil)
        #expect(pair.pendingRotation == false)
        #expect(pair.rotationAttempts == 0)
    }

    @Test("Round-trip preserves all new fields")
    func roundTripNewFields() throws {
        let original = SyncPair(
            logseqUUID: "abc-123",
            reminderLocalId: "local-1",
            reminderExtId: "ext-1",
            lastStatus: "Doing",
            lastOpenStatus: "Doing",
            lastCompleted: false,
            lastLogseqUpdated: 1748390400000,
            lastReminderMod: 1748390400000,
            lastTitle: "Test",
            lastNotesHash: "abc",
            lastDueDateMs: 1748390400000,
            lastDueSource: .scheduled,
            pendingRotation: true,
            rotationAttempts: 3
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(SyncPair.self, from: data)
        #expect(decoded.lastDueDateMs == 1748390400000)
        #expect(decoded.lastDueSource == .scheduled)
        #expect(decoded.pendingRotation == true)
        #expect(decoded.rotationAttempts == 3)
    }

    @Test("LogseqDateField encodes and decodes with stable raw values")
    func dateFieldRawValues() throws {
        #expect(LogseqDateField.deadline.rawValue == "deadline")
        #expect(LogseqDateField.scheduled.rawValue == "scheduled")
        let encoded = try JSONEncoder().encode(LogseqDateField.deadline)
        let decoded = try JSONDecoder().decode(LogseqDateField.self, from: encoded)
        #expect(decoded == .deadline)
    }

    @Test("SyncState containing legacy pairs decodes non-empty")
    func stateWithLegacyPairs() throws {
        let stateJSON = """
        {
            "pairs": [
                {
                    "logseqUUID": "aaa",
                    "reminderLocalId": "loc1",
                    "reminderExtId": "ext1",
                    "lastStatus": "Doing",
                    "lastOpenStatus": "Doing",
                    "lastCompleted": false,
                    "lastLogseqUpdated": 1748000000000,
                    "lastTitle": "T",
                    "lastNotesHash": "h"
                }
            ],
            "captures": [],
            "lastRunDate": null
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(SyncState.self, from: stateJSON)
        #expect(state.pairs.count == 1)
        #expect(state.pairs[0].pendingRotation == false)
    }
}
