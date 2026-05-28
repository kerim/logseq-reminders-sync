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

    // MARK: - Priority

    @Test("Legacy pair without lastPriority decodes as nil")
    func legacyDecodesNilPriority() throws {
        let pair = try JSONDecoder().decode(SyncPair.self, from: legacyJSON)
        #expect(pair.lastPriority == nil)
    }

    @Test("Pair with lastPriority round-trips")
    func priorityRoundTrip() throws {
        let original = SyncPair(
            logseqUUID: "p-1", reminderLocalId: "loc", reminderExtId: "ext",
            lastStatus: "Doing", lastOpenStatus: "Doing", lastCompleted: false,
            lastLogseqUpdated: 0, lastReminderMod: nil,
            lastTitle: "t", lastNotesHash: "h",
            lastPriority: .urgent
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SyncPair.self, from: data)
        #expect(decoded.lastPriority == .urgent)
    }

    @Test("Unknown lastPriority rawValue tolerates instead of throwing")
    func unknownPriorityRawValueDecodesAsNil() throws {
        // Hypothetical future "Critical" written by a newer build. A strict
        // decode (`try c.decodeIfPresent`) would throw `dataCorrupted` and tank
        // the whole pair; we use `try?` to fall back to nil so state.json
        // self-heals on the next sync.
        let strangeJSON = """
        {
            "logseqUUID": "p-2",
            "reminderLocalId": "loc",
            "reminderExtId": "ext",
            "lastStatus": "Doing",
            "lastOpenStatus": "Doing",
            "lastCompleted": false,
            "lastLogseqUpdated": 0,
            "lastTitle": "t",
            "lastNotesHash": "h",
            "lastPriority": "Critical"
        }
        """.data(using: .utf8)!
        let pair = try JSONDecoder().decode(SyncPair.self, from: strangeJSON)
        #expect(pair.lastPriority == nil)
        #expect(pair.logseqUUID == "p-2")
    }
}
