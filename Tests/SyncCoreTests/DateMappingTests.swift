import Testing
import Foundation
@testable import SyncCore

@Suite("DateMapping")
struct DateMappingTests {

    // Fixed UTC calendar so tests are TZ-independent.
    private var utcCal: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    @Test("epochMsToDueComponents strips hour/minute for midnight (date-only)")
    func dateOnlyOmitsTime() {
        // 2026-05-28 00:00:00 UTC — midnight in UTC means date-only.
        let ms: Int64 = 1779926400000
        let comps = Mapper.epochMsToDueComponents(ms, calendar: utcCal)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 28)
        // Hour and minute omitted — Apple Reminders renders as all-day.
        #expect(comps.hour == nil)
        #expect(comps.minute == nil)
    }

    @Test("epochMsToDueComponents preserves time-of-day for non-midnight ms")
    func timeOfDayPreserved() {
        // 2026-05-28 12:45:00 UTC
        let ms: Int64 = 1779972300000
        let comps = Mapper.epochMsToDueComponents(ms, calendar: utcCal)
        #expect(comps.year == 2026)
        #expect(comps.month == 5)
        #expect(comps.day == 28)
        #expect(comps.hour == 12)
        #expect(comps.minute == 45)
        let back = Mapper.dueComponentsToEpochMs(comps, calendar: utcCal)
        #expect(back == ms)
    }

    @Test("dueComponentsToEpochMs with full date returns non-nil")
    func nonNilForFullDate() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 28
        comps.hour = 0; comps.minute = 0
        let result = Mapper.dueComponentsToEpochMs(comps, calendar: utcCal)
        #expect(result != nil)
        #expect(result == 1779926400000)
    }

    @Test("dueComponentsToEpochMs with date-only (no h/m) returns midnight ms")
    func dateOnlyToMidnightMs() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 5; comps.day = 28
        // No hour/minute — should map to midnight in the given calendar.
        let result = Mapper.dueComponentsToEpochMs(comps, calendar: utcCal)
        #expect(result != nil)
        #expect(result == 1779926400000)
    }

    @Test("preferredDateField returns deadline when both set")
    func preferDeadline() {
        #expect(Mapper.preferredDateField(deadline: 1000, scheduled: 2000) == .deadline)
    }

    @Test("preferredDateField returns scheduled when only scheduled set")
    func preferScheduled() {
        #expect(Mapper.preferredDateField(deadline: nil, scheduled: 2000) == .scheduled)
    }

    @Test("preferredDateField returns nil when neither set")
    func preferNil() {
        #expect(Mapper.preferredDateField(deadline: nil, scheduled: nil) == nil)
    }
}
