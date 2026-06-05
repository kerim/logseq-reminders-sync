import EventKit
import Foundation
import ReminderKitBridge
import SyncCore

enum URLAttachmentResult {
    case written
    case alreadyCorrect
    case notFound
    case failed
}

actor RemindersStore {
    private let store = EKEventStore()
    /// Keyed by Logseq status name ("Doing", "Todo", etc.)
    private var calendars: [String: EKCalendar] = [:]
    /// The optional "Logseq Notes" list, when configured and present. Resolved alongside
    /// the status lists but kept separate — notes are imported one-way, never routed by
    /// status. `EKCalendar` stays inside the actor (never escapes).
    private var notesCalendar: EKCalendar?

    // MARK: - Authorization

    func authorize() async throws {
        if #available(macOS 14.0, *) {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else { throw RemindersError.accessDenied }
            let status = EKEventStore.authorizationStatus(for: .reminder)
            guard status == .fullAccess else { throw RemindersError.accessDenied }
        } else {
            throw RemindersError.unsupportedOS
        }
    }

    // MARK: - Calendar / List resolution

    /// Resolve all five status→list entries from config. Throws a clear error if any
    /// list ID cannot be found, so a mis-configured statusLists fails loudly.
    func resolveCalendars(config: Config) throws {
        let allCals = store.calendars(for: .reminder)
        var resolved: [String: EKCalendar] = [:]
        var missing: [String] = []

        for (status, entry) in config.statusLists {
            if let cal = allCals.first(where: { $0.calendarIdentifier == entry.id }) {
                resolved[status] = cal
            } else if let cal = allCals.first(where: { $0.title == entry.title }) {
                resolved[status] = cal
            } else {
                missing.append("\(status) -> \"\(entry.title)\" (id: \(entry.id))")
            }
        }

        if !missing.isEmpty {
            throw RemindersError.listsNotFound(
                "statusLists entries not found in Reminders:\n" +
                missing.map { "  • \($0)" }.joined(separator: "\n") +
                "\nUpdate statusLists in ~/.logseq-reminders-sync/config.json with the correct IDs."
            )
        }
        calendars = resolved

        // Resolve the OPTIONAL "Logseq Notes" list. Unlike the five status lists, a
        // missing notes list must NOT break sync — warn and leave it nil. Always
        // (re)assign so a re-resolve after the list is dropped can't leave a stale value.
        if let entry = config.notesList {
            if let cal = allCals.first(where: { $0.calendarIdentifier == entry.id })
                ?? allCals.first(where: { $0.title == entry.title }) {
                notesCalendar = cal
            } else {
                notesCalendar = nil
                fputs("WARN: notes list \"\(entry.title)\" (id: \(entry.id)) not found " +
                      "— note import disabled this run.\n", stderr)
            }
        } else {
            notesCalendar = nil
        }
    }

    /// All reminder calendars (for diagnostic --dump-reminders).
    func allCalendars() -> [(title: String, calendarIdentifier: String)] {
        store.calendars(for: .reminder).map { ($0.title, $0.calendarIdentifier) }
    }

    /// Find a reminder list by exact title, or create one with that title. Returns the
    /// `calendarIdentifier` (a String) — `EKCalendar` never escapes the actor. Used by
    /// `setup`. Idempotent: re-running reuses the same-named list instead of duplicating.
    func findOrCreateList(title: String) throws -> String {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == title }) {
            return existing.calendarIdentifier
        }
        guard let source = reminderSource() else {
            throw RemindersError.noReminderSource
        }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = title
        cal.source = source
        try store.saveCalendar(cal, commit: true)
        return cal.calendarIdentifier
    }

    /// Pick a source that can hold reminder lists: the one backing the default reminders
    /// calendar, else a source with an existing writable reminder calendar, else a local
    /// source, else any source.
    private func reminderSource() -> EKSource? {
        if let s = store.defaultCalendarForNewReminders()?.source { return s }
        if let s = store.calendars(for: .reminder).first(where: { !$0.isImmutable })?.source { return s }
        return store.sources.first(where: { $0.sourceType == .local }) ?? store.sources.first
    }

    /// The set of all managed calendar IDs (for diagnostic display).
    func managedCalendarTitles() -> [String: String] {
        Dictionary(uniqueKeysWithValues: calendars.map { ($0.key, $0.value.title) })
    }

    // MARK: - Fetching (strictly scoped to the 5 managed calendars)

    func fetchIncomplete() async throws -> [ReminderSnapshot] {
        let cals = resolvedCalendars()
        return try await fetch(predicate: store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: cals
        ))
    }

    func fetchCompleted(since: Date) async throws -> [ReminderSnapshot] {
        let cals = resolvedCalendars()
        return try await fetch(predicate: store.predicateForCompletedReminders(
            withCompletionDateStarting: since, ending: nil, calendars: cals
        ))
    }

    /// Cheap change-signal for the smart-polling gate: incomplete count per managed
    /// list, plus the max `lastModifiedDate` (epoch ms) across incomplete +
    /// completed-in-the-last-7-days reminders. Per-list counts catch a managed→managed
    /// move (which leaves the total unchanged); the max-modified catches edits and
    /// completions. Uses a fixed 7-day completed window (independent of the engine's
    /// lastRunDate lookback) so a run of skips doesn't shrink it. Throws if no
    /// calendars are resolved, so a mis-sequenced caller fails safe to a full run.
    func changeSignal() async throws -> (listCounts: [String: Int], maxModifiedMs: Int64) {
        guard !resolvedCalendars().isEmpty else { throw RemindersError.calendarNotResolved }

        let incomplete = try await fetchIncomplete()
        let since = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let completed = try await fetchCompleted(since: since)

        var counts: [String: Int] = [:]
        for snap in incomplete { counts[snap.listId, default: 0] += 1 }

        let maxModifiedMs = (incomplete + completed)
            .compactMap { $0.lastModified.map { Int64($0.timeIntervalSince1970 * 1000) } }
            .max() ?? 0

        return (counts, maxModifiedMs)
    }

    /// Fetch a single live reminder by localId. Store-wide (not scoped to managed lists)
    /// so it can reconcile known pairs regardless of which list they're in.
    func fetchSnapshot(localId: String) -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return nil
        }
        return Self.snapshot(from: item)
    }

    private func resolvedCalendars() -> [EKCalendar] {
        var cals = Array(calendars.values)
        // Include the notes list in fetch scope (fetchIncomplete/fetchCompleted) AND the
        // change-signal, so adding a note triggers a sync pass without the 60-min backstop.
        if let notesCalendar { cals.append(notesCalendar) }
        return cals
    }

    private func fetch(predicate: NSPredicate) async throws -> [ReminderSnapshot] {
        try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: RemindersError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders.map { Self.snapshot(from: $0) })
            }
        }
    }

    // MARK: - Writing

    func createReminder(
        title: String,
        notes: String,
        dueComponents: DateComponents?,
        priority: Int = 0,
        inListId: String
    ) throws -> ReminderSnapshot {
        guard let cal = calendar(forListId: inListId) else {
            throw RemindersError.calendarNotResolved
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = cal
        reminder.title = title
        reminder.notes = notes
        reminder.dueDateComponents = dueComponents
        reminder.priority = priority
        try store.save(reminder, commit: true)
        return Self.snapshot(from: reminder)
    }

    /// Move a reminder to a different managed list by reassigning .calendar.
    /// Returns the post-move snapshot so the engine reads the fresh localId/extId/lastModified
    /// directly without re-fetching by a possibly-stale localId.
    func moveReminder(localId: String, toListId: String) throws -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return nil
        }
        guard item.calendar?.calendarIdentifier != toListId else {
            return Self.snapshot(from: item)   // already in the right list, no-op
        }
        guard let targetCal = calendar(forListId: toListId) else {
            throw RemindersError.calendarNotResolved
        }
        item.calendar = targetCal
        try store.save(item, commit: true)
        return Self.snapshot(from: item)
    }

    /// Read the URL the user attached to a reminder (the field Reminders.app
    /// displays), or nil if none / not found. Read at capture time so a shared
    /// web URL survives import into Logseq.
    func readURLAttachment(localId: String) -> String? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return nil }
        return LRSReadReminderURLAttachment(item)
    }

    /// Write the Logseq backlink into the REMURLAttachment that Reminders.app
    /// displays in its URL field (via the private ReminderKit framework).
    @discardableResult
    func setURLAttachment(localId: String, url: URL?) -> URLAttachmentResult {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return .notFound
        }
        let target = url?.absoluteString
        if LRSReadReminderURLAttachment(item) == target { return .alreadyCorrect }
        return LRSWriteReminderURLAttachment(item, target) ? .written : .failed
    }

    /// Update title/notes/completion. Pass nil to leave a field unchanged. Treats "not found" as success.
    @discardableResult
    func updateReminder(
        localId: String,
        title: String? = nil,
        notes: String? = nil,
        isCompleted: Bool? = nil
    ) throws -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return nil
        }
        if let t = title { item.title = t }
        if let n = notes { item.notes = n }
        if let c = isCompleted {
            item.isCompleted = c
            item.completionDate = c ? Date() : nil
        }
        try store.save(item, commit: true)
        return Self.snapshot(from: item)
    }

    func setDueComponents(localId: String, _ components: DateComponents) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.dueDateComponents = components
        try store.save(item, commit: true)
    }

    func clearDueComponents(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.dueDateComponents = nil
        try store.save(item, commit: true)
    }

    func setPriority(localId: String, _ priority: Int) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.priority = priority
        try store.save(item, commit: true)
    }

    func completeReminder(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.isCompleted = true
        item.completionDate = Date()
        try store.save(item, commit: true)
    }

    func uncompleteReminder(localId: String) throws -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return nil }
        item.isCompleted = false
        item.completionDate = nil
        try store.save(item, commit: true)
        return Self.snapshot(from: item)
    }

    func deleteReminder(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        try store.remove(item, commit: true)
    }

    /// Delete every reminder — incomplete AND completed, across an unbounded window — in
    /// the five managed lists (the lists themselves are kept). Used by `switch-graph`'s
    /// full clean. The continuation carries only `String` localIds (never the non-Sendable
    /// `EKReminder`); removals are staged with `commit:false` on the actor and flushed once.
    func emptyManagedLists(config: Config) async throws {
        let cals = managedCalendars(config: config)
        guard !cals.isEmpty else { return }
        let ids = try await managedReminderLocalIds(cals)
        var removedAny = false
        do {
            for id in ids {
                if let item = store.calendarItem(withIdentifier: id) as? EKReminder {
                    try store.remove(item, commit: false)
                    removedAny = true
                }
            }
            if removedAny { try store.commit() }
        } catch {
            // Discard any staged-but-uncommitted deletions so the store/actor is left
            // in a clean state (the caller aborts before flipping config either way).
            store.reset()
            throw error
        }
    }

    /// Delete every managed list (five status lists + the optional notes list) from the
    /// Reminders store. Commits per calendar so a single failure doesn't block the rest.
    /// Re-fetches each calendar by identifier inside the loop — `store.reset()` (called on
    /// catch) invalidates any EKCalendar fetched before the loop started.
    /// Returns the count of lists deleted and titles of any that could not be removed.
    func deleteManagedLists(config: Config) async throws -> (deleted: Int, failed: [String]) {
        let pairs: [(id: String, title: String)] = managedCalendars(config: config)
            .map { ($0.calendarIdentifier, $0.title) }
        var deleted = 0
        var failed: [String] = []
        for (id, title) in pairs {
            guard let cal = store.calendars(for: .reminder)
                .first(where: { $0.calendarIdentifier == id }) else {
                deleted += 1   // already gone — count as success
                continue
            }
            do {
                try store.removeCalendar(cal, commit: true)
                deleted += 1
            } catch {
                store.reset()
                failed.append(title)
            }
        }
        return (deleted, failed)
    }

    /// Count reminders (incomplete + completed, unbounded) still in the managed lists —
    /// `switch-graph`'s post-empty verification read.
    func countRemaining(inManagedLists config: Config) async throws -> Int {
        let cals = managedCalendars(config: config)
        guard !cals.isEmpty else { return 0 }
        return try await managedReminderLocalIds(cals).count
    }

    /// Calendars that `switch-graph` empties + verifies. This is the ONLY place the notes
    /// list is treated as "managed": both `emptyManagedLists` and `countRemaining` go
    /// through here, so they stay symmetric. `Config.managedListIds` itself is left
    /// notes-free (notes must not be routed by status / adopted as mirror tasks).
    private func managedCalendars(config: Config) -> [EKCalendar] {
        var ids = config.managedListIds
        if let notesId = config.notesListId { ids.insert(notesId) }
        return store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) }
    }

    /// All localIds (incomplete + completed, unbounded) across the given calendars.
    private func managedReminderLocalIds(_ cals: [EKCalendar]) async throws -> [String] {
        let incomplete = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: cals
        )
        let completed = store.predicateForCompletedReminders(
            withCompletionDateStarting: nil, ending: nil, calendars: cals
        )
        let a = try await localIds(matching: incomplete)
        let b = try await localIds(matching: completed)
        return a + b
    }

    private func localIds(matching predicate: NSPredicate) async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: RemindersError.fetchFailed)
                    return
                }
                continuation.resume(returning: reminders.map { $0.calendarItemIdentifier })
            }
        }
    }

    // MARK: - Helpers

    private func calendar(forListId listId: String) -> EKCalendar? {
        calendars.values.first(where: { $0.calendarIdentifier == listId })
    }

    // MARK: - Snapshot construction (stays inside actor — EKReminder is non-Sendable)

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(
            localId: reminder.calendarItemIdentifier,
            extId: reminder.calendarItemExternalIdentifier ?? "",
            listId: reminder.calendar?.calendarIdentifier ?? "",
            title: reminder.title ?? "",
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            completionDate: reminder.completionDate,
            lastModified: reminder.lastModifiedDate,
            dueComponents: reminder.dueDateComponents,
            priority: reminder.priority
        )
    }
}

// MARK: - Errors

enum RemindersError: Error, LocalizedError {
    case accessDenied
    case unsupportedOS
    case calendarNotFound(String)
    case listsNotFound(String)
    case calendarNotResolved
    case fetchFailed
    case reminderNotFound(String)
    case noReminderSource

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access denied. Grant Full Access in System Settings → Privacy → Reminders."
        case .unsupportedOS:
            return "macOS 14+ is required."
        case .noReminderSource:
            return "No Reminders account is available to hold new lists. Open Reminders.app and " +
                   "make sure at least one account (iCloud or On My Mac) is enabled, then re-run setup."
        case .calendarNotFound(let name):
            return "Reminders list '\(name)' not found."
        case .listsNotFound(let msg):
            return msg
        case .calendarNotResolved:
            return "Calendar not resolved — call resolveCalendars(config:) first."
        case .fetchFailed:
            return "EventKit fetch returned nil."
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        }
    }
}
