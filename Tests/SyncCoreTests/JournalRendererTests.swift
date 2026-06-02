import Foundation
import Testing
@testable import SyncCore

@Suite("JournalRenderer")
struct JournalRendererTests {

    // MARK: - Helpers

    static func makeCalendar(timeZoneId: String = "America/New_York") -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: timeZoneId)!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }

    static func makeDate(year: Int, month: Int, day: Int, hour: Int = 12,
                         calendar: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day; comps.hour = hour
        return calendar.date(from: comps)!
    }

    // MARK: - Canonical case

    @Test func canonicalFormat() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal) == "Jun 2nd, 2026")
    }

    // MARK: - Ordinal edges

    @Test func ordinal1st() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 1, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("1st") == true)
    }

    @Test func ordinal2nd() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 2, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("2nd") == true)
    }

    @Test func ordinal3rd() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 3, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("3rd") == true)
    }

    @Test func ordinal4th() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 4, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("4th") == true)
    }

    @Test func ordinal11th() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 11, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("11th") == true)
    }

    @Test func ordinal21st() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 21, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("21st") == true)
    }

    @Test func ordinal22nd() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 22, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("22nd") == true)
    }

    @Test func ordinal23rd() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 1, day: 23, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMM do, yyyy", calendar: cal)?.contains("23rd") == true)
    }

    // MARK: - Token variety

    @Test func fullMonthFormat() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "MMMM do, yyyy", calendar: cal) == "June 2nd, 2026")
    }

    @Test func weekdayFormat() {
        // June 2, 2026 is a Tuesday
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "EEE, MMM do, yyyy", calendar: cal) == "Tue, Jun 2nd, 2026")
    }

    // MARK: - Unsupported token → nil (safe-degrade)

    @Test func unsupportedTokenDegrades() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(renderJournalTitle(date: date, format: "W MMM do, yyyy", calendar: cal) == nil)
    }

    // MARK: - Quoted literal

    @Test func quotedLiteral() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(
            renderJournalTitle(date: date, format: "EEE, 'the' do 'of' MMM yyyy", calendar: cal)
            == "Tue, the 2nd of Jun 2026"
        )
    }

    // MARK: - Near-midnight timezone

    @Test func nearMidnightTimezone() {
        // 23:30 UTC on June 1 = 02:30 in Helsinki (UTC+3 in summer)
        // → UTC sees June 1, Helsinki sees June 2
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!

        var localCal = Calendar(identifier: .gregorian)
        localCal.timeZone = TimeZone(identifier: "Europe/Helsinki")!

        // Build the date as June 1 23:30 UTC
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 1
        comps.hour = 23; comps.minute = 30
        comps.timeZone = TimeZone(identifier: "UTC")
        let date = Calendar(identifier: .gregorian).date(from: comps)!

        #expect(journalDay(for: date, calendar: utcCal) == 20260601)
        #expect(journalDay(for: date, calendar: localCal) == 20260602)
    }

    // MARK: - journalDay consistency

    @Test func journalDayConsistency() {
        let cal = Self.makeCalendar()
        let date = Self.makeDate(year: 2026, month: 6, day: 2, calendar: cal)
        #expect(journalDay(for: date, calendar: cal) == 20260602)
    }
}
