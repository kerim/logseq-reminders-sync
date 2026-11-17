import Testing
@testable import SyncCore

/// In-memory graph of pages. `parse` stands in for Logseq's title parsing: it maps a
/// new page's title to the journal day it becomes, or nil for a plain page.
private actor FakeGraph: JournalPageOps {
    struct Page { let id: Int; var title: String; var day: Int?; var recycled = false }
    private(set) var pages: [Page] = []
    private(set) var created: [String] = []
    let parse: @Sendable (String) -> Int?
    var failRecycle = false
    private var nextId = 100

    init(pages: [(String, Int?)] = [], parse: @escaping @Sendable (String) -> Int?) {
        self.parse = parse
        for (t, d) in pages { addPage(t, d) }
    }

    @discardableResult private func addPage(_ title: String, _ day: Int?) -> Int {
        nextId += 1
        pages.append(Page(id: nextId, title: title, day: day))
        return nextId
    }

    func setFailRecycle() { failRecycle = true }

    private var live: [Page] { pages.filter { !$0.recycled } }

    func journalTitle(day: Int) async throws -> String? { live.first { $0.day == day }?.title }

    func pageExists(lowercasedTitle: String) async throws -> Bool {
        live.contains { $0.title.lowercased() == lowercasedTitle }
    }

    func createPage(title: String) async throws -> Int {
        created.append(title)
        let day = parse(title)
        // Like Logseq: a title that parses to an existing journal's day returns that journal.
        if let day, let existing = live.first(where: { $0.day == day }) { return existing.id }
        return addPage(title, day)
    }

    func journalDay(ofPage id: Int) async throws -> Int? { pages.first { $0.id == id }?.day }

    func recyclePage(id: Int) async throws {
        struct Boom: Error {}
        if failRecycle { throw Boom() }
        if let i = pages.firstIndex(where: { $0.id == id }) { pages[i].recycled = true }
    }
}

@Suite struct JournalCreatorTests {
    let today = 20261117
    let title = "Nov 17th, 2026"

    @Test func existingJournalIsReturnedWithoutWriting() async throws {
        let g = FakeGraph(pages: [(title, today)]) { _ in nil }
        #expect(try await ensureJournalPage(day: today, title: title, ops: g) == title)
        #expect(await g.created.isEmpty)
    }

    @Test func missingJournalIsCreated() async throws {
        let g = FakeGraph(pages: [("Nov 16th, 2026", 20261116)]) { $0 == "Nov 17th, 2026" ? 20261117 : nil }
        #expect(try await ensureJournalPage(day: today, title: title, ops: g) == title)
        #expect(await g.created == [title])
    }

    @Test func plainPageWithSameTitleBlocksCreate() async throws {
        let g = FakeGraph(pages: [("nov 17TH, 2026", nil)]) { _ in today }
        await #expect(throws: JournalCreateError.titleTakenByPlainPage(title: title)) {
            try await ensureJournalPage(day: today, title: title, ops: g)
        }
        #expect(await g.created.isEmpty)
    }

    @Test func titleThatIsNotADateIsRecycledAndReported() async throws {
        let g = FakeGraph { _ in nil }
        await #expect(throws: JournalCreateError.notAJournal(title: title, recycled: true)) {
            try await ensureJournalPage(day: today, title: title, ops: g)
        }
        #expect(await g.pages.allSatisfy(\.recycled))
    }

    @Test func titleReadAsAnotherDayLeavesThatJournalAlone() async throws {
        // The user's own journal for the 16th must never be recycled.
        let g = FakeGraph(pages: [("Nov 16th, 2026", 20261116)]) { _ in 20261116 }
        await #expect(throws: JournalCreateError.notAJournal(title: title, recycled: false)) {
            try await ensureJournalPage(day: today, title: title, ops: g)
        }
        #expect(await g.pages.allSatisfy { !$0.recycled })
    }

    @Test func failedRecycleStillReportsTheRealProblem() async throws {
        let g = FakeGraph { _ in nil }
        await g.setFailRecycle()
        await #expect(throws: JournalCreateError.notAJournal(title: title, recycled: false)) {
            try await ensureJournalPage(day: today, title: title, ops: g)
        }
    }
}
