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
    }

    /// All reminder calendars (for diagnostic --dump-reminders).
    func allCalendars() -> [(title: String, calendarIdentifier: String)] {
        store.calendars(for: .reminder).map { ($0.title, $0.calendarIdentifier) }
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

    /// Fetch a single live reminder by localId. Store-wide (not scoped to managed lists)
    /// so it can reconcile known pairs regardless of which list they're in.
    func fetchSnapshot(localId: String) -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return nil
        }
        return Self.snapshot(from: item)
    }

    private func resolvedCalendars() -> [EKCalendar] {
        Array(calendars.values)
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

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Reminders access denied. Grant Full Access in System Settings → Privacy → Reminders."
        case .unsupportedOS:
            return "macOS 14+ is required."
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
