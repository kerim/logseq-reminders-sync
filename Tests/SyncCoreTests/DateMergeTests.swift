import Testing
import Foundation
@testable import SyncCore

/// Tests for the pure date-merge decision (`Mapper.dateMergeAction`). These prove the
/// DECISION LOGIC converges — they do not exercise the SyncEngine executor's writes or the
/// reminder write→read round-trip (`epochMsToDueComponents`∘`dueComponentsToEpochMs`),
/// which is exact for Logseq's midnight/minute-granular dates but strips sub-minute
/// precision. That last hop is covered by the live two-pass check, not here, so the
/// "cannot recur" guarantee is scoped to the logic path.
@Suite("DateMerge")
struct DateMergeTests {

    private let A: Int64 = 1_779_984_000_000   // a Logseq date
    private let B: Int64 = 1_780_202_705_172   // a different date

    // MARK: - Baseline establishment (lastDueMs == nil)

    @Test func baselineBothEmpty() {
        let action = Mapper.dateMergeAction(
            logseqMs: nil, reminderMs: nil, logseqField: nil,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: 100)
        #expect(action == .noChange)
    }

    @Test func baselineLogseqOnlySeedsReminder() {
        // The reported wipe scenario at first-enable: Logseq has a date, reminder empty.
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: nil, logseqField: .scheduled,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: nil)
        #expect(action == .pushToReminder(ms: A, source: .scheduled))
    }

    @Test func baselineBothAgreeRecordsOnly() {
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: A, logseqField: .scheduled,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: 100)
        #expect(action == .recordBaseline(ms: A, source: .scheduled))
    }

    @Test func baselineReminderOnlySeedsLogseq() {
        // Mirror wipe scenario: only the reminder has a date.
        let action = Mapper.dateMergeAction(
            logseqMs: nil, reminderMs: A, logseqField: nil,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: 200)
        #expect(action == .pushToLogseq(ms: A, source: .scheduled))
    }

    @Test func baselineDivergenceLogseqWins() {
        // Both sides hold DIFFERENT dates at first baseline → Logseq wins, seed reminder.
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: B, logseqField: .scheduled,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: 999)
        #expect(action == .pushToReminder(ms: A, source: .scheduled))
    }

    @Test func baselineDeadlineSourcePreserved() {
        // Exercises the `source` arm: a Logseq DEADLINE (not scheduled) must round-trip.
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: nil, logseqField: .deadline,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: nil)
        #expect(action == .pushToReminder(ms: A, source: .deadline))
    }

    // MARK: - Steady-state 3-way (lastDueMs != nil)

    @Test func steadyNoChange() {
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: A, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 100, reminderUpdatedMs: 100)
        #expect(action == .noChange)
    }

    @Test func steadyLogseqChangedPushesReminder() {
        let action = Mapper.dateMergeAction(
            logseqMs: B, reminderMs: A, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 100, reminderUpdatedMs: 50)
        #expect(action == .pushToReminder(ms: B, source: .scheduled))
    }

    @Test func steadyReminderChangedPushesLogseq() {
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: B, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 50, reminderUpdatedMs: 100)
        #expect(action == .pushToLogseq(ms: B, source: .scheduled))
    }

    @Test func steadyReminderClearedPushesClearToLogseq() {
        let action = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: nil, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 50, reminderUpdatedMs: 100)
        #expect(action == .pushToLogseq(ms: nil, source: .scheduled))
    }

    @Test func steadyLogseqClearedPushesClearToReminder() {
        let action = Mapper.dateMergeAction(
            logseqMs: nil, reminderMs: A, logseqField: nil,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 100, reminderUpdatedMs: 50)
        #expect(action == .pushToReminder(ms: nil, source: nil))
    }

    // MARK: - Conflict (both changed)

    @Test func conflictLogseqNewerWins() {
        let action = Mapper.dateMergeAction(
            logseqMs: B, reminderMs: A, logseqField: .scheduled,
            lastDueMs: 1_000, lastDueSource: .scheduled,
            logseqUpdatedMs: 300, reminderUpdatedMs: 200)
        #expect(action == .pushToReminder(ms: B, source: .scheduled))
    }

    @Test func conflictReminderNewerWins() {
        let action = Mapper.dateMergeAction(
            logseqMs: B, reminderMs: A, logseqField: .scheduled,
            lastDueMs: 1_000, lastDueSource: .scheduled,
            logseqUpdatedMs: 200, reminderUpdatedMs: 300)
        #expect(action == .pushToLogseq(ms: A, source: .scheduled))
    }

    @Test func conflictNilReminderTimestampLogseqWins() {
        // reminderUpdatedMs nil → treated as 0 → Logseq (>=) wins.
        let action = Mapper.dateMergeAction(
            logseqMs: B, reminderMs: A, logseqField: .scheduled,
            lastDueMs: 1_000, lastDueSource: .scheduled,
            logseqUpdatedMs: 1, reminderUpdatedMs: nil)
        #expect(action == .pushToReminder(ms: B, source: .scheduled))
    }

    // MARK: - Ping-pong / regression guards (two-pass, both wipe directions)

    @Test func regressionLogseqWipePrevented() {
        // Pass 1: Logseq date, empty reminder, no baseline → seed reminder.
        let pass1 = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: nil, logseqField: .scheduled,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: nil)
        #expect(pass1 == .pushToReminder(ms: A, source: .scheduled))
        // Apply that baseline; the reminder now holds the seeded date.
        // Pass 2 must converge — NOT push an empty-reminder clear back to Logseq.
        let pass2 = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: A, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 100, reminderUpdatedMs: 100)
        #expect(pass2 == .noChange)
    }

    @Test func regressionReminderWipePrevented() {
        // Mirror direction. Pass 1: empty Logseq, reminder date, no baseline → seed Logseq.
        let pass1 = Mapper.dateMergeAction(
            logseqMs: nil, reminderMs: A, logseqField: nil,
            lastDueMs: nil, lastDueSource: nil,
            logseqUpdatedMs: 100, reminderUpdatedMs: 200)
        #expect(pass1 == .pushToLogseq(ms: A, source: .scheduled))
        // Apply baseline; Logseq now holds the seeded date.
        // Pass 2 must converge — NOT clear the reminder's date.
        let pass2 = Mapper.dateMergeAction(
            logseqMs: A, reminderMs: A, logseqField: .scheduled,
            lastDueMs: A, lastDueSource: .scheduled,
            logseqUpdatedMs: 100, reminderUpdatedMs: 200)
        #expect(pass2 == .noChange)
    }
}
