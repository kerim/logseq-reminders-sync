import Foundation

/// The graph operations `ensureJournalPage` needs. The executable target implements
/// these with the `logseq` CLI; tests use an in-memory fake.
public protocol JournalPageOps {
    /// Title of the journal page whose `:block/journal-day` is `day`, or nil if none.
    func journalTitle(day: Int) async throws -> String?
    /// True if any page's `:block/name` equals `lowercasedTitle`.
    func pageExists(lowercasedTitle: String) async throws -> Bool
    /// Create a page with this title (or get the page Logseq maps it to). Returns its db id.
    func createPage(title: String) async throws -> Int
    /// The page's `:block/journal-day`, or nil if it is not a journal page.
    func journalDay(ofPage id: Int) async throws -> Int?
    /// Move the page with this db id to Logseq's recycle bin.
    func recyclePage(id: Int) async throws
}

public enum JournalCreateError: Error, LocalizedError, Equatable {
    /// A plain (non-journal) page already has today's journal title.
    case titleTakenByPlainPage(title: String)
    /// Logseq didn't turn the title into today's journal. `recycled` says whether the
    /// stray plain page it made instead was moved to the recycle bin.
    case notAJournal(title: String, recycled: Bool)

    public var errorDescription: String? {
        switch self {
        case .titleTakenByPlainPage(let title):
            return "Today's journal page couldn't be created: a regular page named '\(title)' " +
                "already exists (it may be in Logseq's recycle bin). Rename or permanently delete " +
                "that page, or open Logseq once to create today's journal."
        case .notAJournal(let title, let recycled):
            let cleanup = recycled
                ? " The regular page it made instead was moved to Logseq's recycle bin."
                : ""
            return "Today's journal page couldn't be created: Logseq didn't recognise '\(title)' " +
                "as today's date.\(cleanup) Open Logseq once to create today's journal."
        }
    }
}

/// Return the title of the journal page for `day`, creating it as `title` if it is
/// missing. Logseq decides whether a new page is a journal by parsing its title, so
/// the result is checked afterwards; a stray plain page made instead is recycled.
public func ensureJournalPage(day: Int, title: String, ops: JournalPageOps) async throws -> String {
    if let existing = try await ops.journalTitle(day: day) { return existing }

    // Creating a page whose title an existing plain page already has would just
    // return that page, and the capture would land on it. Recycled pages still match
    // by name, which is wanted: the CLI refuses to create over one ("page is recycled").
    if try await ops.pageExists(lowercasedTitle: title.lowercased()) {
        throw JournalCreateError.titleTakenByPlainPage(title: title)
    }

    let id = try await ops.createPage(title: title)

    if let created = try await ops.journalTitle(day: day) { return created }

    // Only a plain page is ours to remove. If Logseq read the title as some other
    // date, `id` is that date's journal — possibly one the user already had.
    var recycled = false
    if try await ops.journalDay(ofPage: id) == nil {
        // A failed recycle must not hide why the journal wasn't made.
        recycled = (try? await ops.recyclePage(id: id)) != nil
    }
    throw JournalCreateError.notAJournal(title: title, recycled: recycled)
}
