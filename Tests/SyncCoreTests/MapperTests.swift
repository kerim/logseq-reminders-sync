import Foundation
import Testing
@testable import SyncCore

@Suite("Mapper")
struct MapperTests {

    // MARK: - Title transform (Logseq-specific markup)

    @Test func pageLinksUnwrapped() {
        #expect(Mapper.transformTitle("Call [[David]]") == "Call David")
    }

    @Test func multiplePageLinks() {
        #expect(Mapper.transformTitle("[[Work]] meeting with [[Alice]]") == "Work meeting with Alice")
    }

    @Test func hashTagsStripped() {
        #expect(Mapper.transformTitle("Fix #bug in production") == "Fix bug in production")
    }

    @Test func blockRefsStripped() {
        #expect(Mapper.transformTitle("See ((550e8400-e29b-41d4-a716-446655440000))") == "See")
    }

    @Test func noMarkupPassesThrough() {
        #expect(Mapper.transformTitle("Plain text task") == "Plain text task")
    }

    @Test func mixedMarkup() {
        let raw = "Call [[David]] about #project"
        #expect(Mapper.transformTitle(raw) == "Call David about project")
    }

    // MARK: - Page-ref UUID extraction & resolution

    @Test func extractSingleUUID() {
        let uuids = Mapper.extractPageRefUUIDs("Watch [[68f48c70-c9cf-4960-89b1-853802050a5f]] today")
        #expect(uuids == ["68f48c70-c9cf-4960-89b1-853802050a5f"])
    }

    @Test func extractMultipleUUIDs() {
        let text = "[[aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa]] and [[bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb]]"
        let uuids = Mapper.extractPageRefUUIDs(text)
        #expect(uuids.count == 2)
        #expect(uuids.contains("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        #expect(uuids.contains("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    }

    @Test func extractIgnoresNonUUIDPageRefs() {
        #expect(Mapper.extractPageRefUUIDs("Meeting with [[David]] tomorrow").isEmpty)
    }

    @Test func resolvePageRefsReplaces() {
        let titles = ["68f48c70-c9cf-4960-89b1-853802050a5f": "Movies to Watch"]
        let resolved = Mapper.resolvePageRefs("See [[68f48c70-c9cf-4960-89b1-853802050a5f]] list", titles: titles)
        #expect(resolved == "See Movies to Watch list")
    }

    @Test func resolvePageRefsLeavesUnknown() {
        let resolved = Mapper.resolvePageRefs("See [[abcdef00-0000-0000-0000-000000000000]]", titles: [:])
        // Unknown UUID stays in brackets — transformTitle would later strip the brackets
        #expect(resolved.contains("[[abcdef00-0000-0000-0000-000000000000]]"))
    }

    // MARK: - Plain-text-ify (markdown stripping)

    @Test func plainTextifyStripsBold() {
        #expect(Mapper.plainTextify("This is **bold** text") == "This is bold text")
    }

    @Test func plainTextifyStripsItalic() {
        #expect(Mapper.plainTextify("This is *italic* text") == "This is italic text")
    }

    @Test func plainTextifyStripsCode() {
        #expect(Mapper.plainTextify("Run `swift build` now") == "Run swift build now")
    }

    @Test func plainTextifyExtractsLinkLabel() {
        let result = Mapper.plainTextify("See [the docs](https://example.com) here")
        #expect(result == "See the docs here")
    }

    @Test func plainTextifyPlainPassthrough() {
        #expect(Mapper.plainTextify("Just plain text 年級: 5") == "Just plain text 年級: 5")
    }

    // MARK: - Full pipeline

    @Test func plainTextResolvesAndCleans() {
        let titles = ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa": "Alice"]
        let raw = "Call [[aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa]] about **the** project #urgent"
        let result = Mapper.plainText(raw, pageTitles: titles)
        #expect(result == "Call Alice about the project urgent")
    }

    // MARK: - Status mapping

    @Test func doneIsCompleted() {
        #expect(Mapper.logseqStatusIsCompleted("Done") == true)
    }

    @Test func canceledIsNowOpen() {
        // Canceled/Cancelled are routed to the Cancelled list; only Done is completed.
        #expect(Mapper.logseqStatusIsCompleted("Canceled") == false)
        #expect(Mapper.logseqStatusIsCompleted("Cancelled") == false)
    }

    @Test func openStatusesNotCompleted() {
        for status in ["Doing", "Todo", "Backlog", "In Review", "Canceled", "Cancelled"] {
            #expect(Mapper.logseqStatusIsCompleted(status) == false, "Expected \(status) to be open")
        }
    }

    // MARK: - statusMergeAction

    @Test func mergeConvergedWhenBothAgree() {
        let action = Mapper.statusMergeAction(
            logseqStatus: "Doing", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 100, reminderMs: 200, isRecurring: false)
        #expect(action == .converged("Doing"))
    }

    @Test func mergeOnlyLogseqChanged() {
        let action = Mapper.statusMergeAction(
            logseqStatus: "Doing", effectiveReminderStatus: "Todo",
            lastStatus: "Todo", logseqMs: 100, reminderMs: 50, isRecurring: false)
        #expect(action == .pushToReminder("Doing"))
    }

    @Test func mergeOnlyReminderChanged() {
        let action = Mapper.statusMergeAction(
            logseqStatus: "Todo", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 50, reminderMs: 100, isRecurring: false)
        #expect(action == .pushToLogseq("Doing"))
    }

    @Test func mergeBothChangedLogseqWins() {
        let action = Mapper.statusMergeAction(
            logseqStatus: "Backlog", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 200, reminderMs: 100, isRecurring: false)
        #expect(action == .pushToReminder("Backlog"))
    }

    @Test func mergeBothChangedReminderWins() {
        let action = Mapper.statusMergeAction(
            logseqStatus: "Backlog", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 100, reminderMs: 200, isRecurring: false)
        #expect(action == .pushToLogseq("Doing"))
    }

    @Test func mergeTieFoldsToLogseqWins() {
        // A tie must push to reminder (not a no-op), setting lastStatus = logseqStatus.
        let action = Mapper.statusMergeAction(
            logseqStatus: "Backlog", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 100, reminderMs: 100, isRecurring: false)
        #expect(action == .pushToReminder("Backlog"))
    }

    @Test func mergeTiePingPongPrevention() {
        // After a tie, the caller sets lastStatus = logseqStatus ("Backlog").
        // Next pass: logseqStatus="Backlog", effectiveReminderStatus="Backlog" (after write),
        // lastStatus="Backlog" → same-value short-circuit → .converged.
        let secondPass = Mapper.statusMergeAction(
            logseqStatus: "Backlog", effectiveReminderStatus: "Backlog",
            lastStatus: "Backlog", logseqMs: 100, reminderMs: 100, isRecurring: false)
        #expect(secondPass == .converged("Backlog"))
    }

    @Test func mergeSameValueBothChangedConverges() {
        // Both sides moved to "Doing" independently — must converge, no write.
        let action = Mapper.statusMergeAction(
            logseqStatus: "Doing", effectiveReminderStatus: "Doing",
            lastStatus: "Todo", logseqMs: 200, reminderMs: 300, isRecurring: false)
        #expect(action == .converged("Doing"))
    }

    @Test func mergeRecurringDoneDeferred() {
        // Recurring reminder completed → reminder side is "Done"; engine should defer.
        let action = Mapper.statusMergeAction(
            logseqStatus: "Doing", effectiveReminderStatus: "Done",
            lastStatus: "Doing", logseqMs: 50, reminderMs: 200, isRecurring: true)
        #expect(action == .recurringDeferred)
    }

    @Test func mergeRecurringLogseqDoneProceeds() {
        // Logseq-side Done on a recurring block proceeds (reminder still open).
        // The F.2.2 pre-merge guard owns rotation; the merge must not stall here.
        let action = Mapper.statusMergeAction(
            logseqStatus: "Done", effectiveReminderStatus: "Doing",
            lastStatus: "Doing", logseqMs: 200, reminderMs: 50, isRecurring: true)
        #expect(action == .pushToReminder("Done"))
    }

    @Test func restoreDefaultsToDoing() {
        #expect(Mapper.openStatusToRestore(lastOpenStatus: nil) == "Doing")
    }

    @Test func restoreUsesLastOpenStatus() {
        #expect(Mapper.openStatusToRestore(lastOpenStatus: "In Review") == "In Review")
    }

    // MARK: - Notes building (BUILD 10 format)

    @Test func buildNotesStringWithChildren() {
        let notes = Mapper.buildNotesString(childTitlesPlainText: ["Sub-task A", "Sub-task B"])
        #expect(notes == "Sub-task A\nSub-task B")
    }

    @Test func buildNotesStringEmpty() {
        #expect(Mapper.buildNotesString(childTitlesPlainText: []) == "")
    }

    // MARK: - Back-compat extractors (recognise BUILD ≤8 footer formats)

    @Test func extractMirrorUUID() {
        let notes = "Some notes\n---\nlogseq-id: my-block-uuid"
        #expect(Mapper.extractMirrorUUID(from: notes) == "my-block-uuid")
    }

    @Test func extractMirrorUUIDMissing() {
        #expect(Mapper.extractMirrorUUID(from: "No footer here") == nil)
        #expect(Mapper.extractMirrorUUID(from: nil) == nil)
    }

    @Test func extractCaptureUUID() {
        let notes = "original text\n---\nlogseq-captured: journal-abc"
        #expect(Mapper.extractCaptureUUID(from: notes) == "journal-abc")
    }

    @Test func extractCaptureUUIDMissing() {
        #expect(Mapper.extractCaptureUUID(from: "logseq-id: something") == nil)
    }

    // MARK: - Notes hash

    @Test func hashIsConsistent() {
        let h1 = Mapper.hashNotes("hello world")
        let h2 = Mapper.hashNotes("hello world")
        #expect(h1 == h2)
    }

    @Test func hashDifferentForDifferentInputs() {
        #expect(Mapper.hashNotes("abc") != Mapper.hashNotes("def"))
    }

    @Test func hashIsHex64Chars() {
        let h = Mapper.hashNotes("test")
        #expect(h.count == 64)
        #expect(h.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Priority mapping

    @Test("Logseq priority → Apple int",
          arguments: zip(
            [LogseqPriority?.some(.urgent), .some(.high), .some(.medium), .some(.low), nil],
            [1, 5, 9, 0, 0]
          ))
    func logseqPriorityToReminderInt(_ input: LogseqPriority?, _ expected: Int) {
        #expect(Mapper.logseqPriorityToReminder(input) == expected)
    }

    @Test("Apple int → Logseq priority (bucketed)",
          arguments: zip(
            [0, 1, 2, 4, 5, 7, 8, 9, -1, 10],
            [LogseqPriority?.none,
             .some(.urgent), .some(.urgent), .some(.urgent),
             .some(.high), .some(.high), .some(.high),
             .some(.medium),
             nil, nil]
          ))
    func reminderPriorityToLogseqBucket(_ input: Int, _ expected: LogseqPriority?) {
        #expect(Mapper.reminderPriorityToLogseq(input) == expected)
    }

    @Test func priorityRoundTripPreservesNonLowValues() {
        for prio: LogseqPriority in [.urgent, .high, .medium] {
            let apple = Mapper.logseqPriorityToReminder(prio)
            #expect(Mapper.reminderPriorityToLogseq(apple) == prio)
        }
    }

    @Test func priorityRoundTripLowCollapsesToNil() {
        // Logseq "Low" intentionally round-trips to nil (no priority).
        let apple = Mapper.logseqPriorityToReminder(.low)
        #expect(apple == 0)
        #expect(Mapper.reminderPriorityToLogseq(apple) == nil)
    }

    @Test func forSyncDropsLow() {
        #expect(LogseqPriority.low.forSync == nil)
        #expect(LogseqPriority.urgent.forSync == .urgent)
        #expect(LogseqPriority.high.forSync == .high)
        #expect(LogseqPriority.medium.forSync == .medium)
    }

    // MARK: - Logseq deep link

    @Test func deepLinkSimpleGraph() {
        let url = Mapper.logseqDeepLink(
            graph: "reminders-test-10",
            blockUUID: "6a16c3b1-d5a2-4092-9f7e-c3686bbe49d7")
        #expect(url?.absoluteString
            == "logseq://graph/reminders-test-10?block-id=6a16c3b1-d5a2-4092-9f7e-c3686bbe49d7")
    }

    @Test func deepLinkEncodesSpaceInGraphName() {
        // The configured graph here has no spaces, so this is the only place the
        // percent-encoding path is exercised: a space must become %20.
        let url = Mapper.logseqDeepLink(
            graph: "My Graph",
            blockUUID: "6a16c3b1-d5a2-4092-9f7e-c3686bbe49d7")
        #expect(url?.absoluteString
            == "logseq://graph/My%20Graph?block-id=6a16c3b1-d5a2-4092-9f7e-c3686bbe49d7")
    }

    @Test func deepLinkQueryItemIsBlockId() {
        let uuid = "6a16c3b1-d5a2-4092-9f7e-c3686bbe49d7"
        let url = Mapper.logseqDeepLink(graph: "g", blockUUID: uuid)
        let comps = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let item = comps?.queryItems?.first
        #expect(item?.name == "block-id")
        #expect(item?.value == uuid)
    }
}
