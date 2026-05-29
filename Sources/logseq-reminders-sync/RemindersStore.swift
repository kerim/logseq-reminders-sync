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
    private var calendar: EKCalendar?

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

    func resolveCalendar(listId: String, listTitle: String) throws -> String {
        let calendars = store.calendars(for: .reminder)

        if !listId.isEmpty, let cal = calendars.first(where: { $0.calendarIdentifier == listId }) {
            calendar = cal
            return cal.calendarIdentifier
        }

        guard let cal = calendars.first(where: { $0.title == listTitle }) else {
            throw RemindersError.calendarNotFound(listTitle)
        }
        calendar = cal
        return cal.calendarIdentifier
    }

    func allCalendars() -> [(title: String, calendarIdentifier: String)] {
        store.calendars(for: .reminder).map { ($0.title, $0.calendarIdentifier) }
    }

    // MARK: - Fetching

    func fetchIncomplete() async throws -> [ReminderSnapshot] {
        guard let cal = calendar else { throw RemindersError.calendarNotResolved }
        return try await fetch(predicate: store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: [cal]
        ))
    }

    func fetchCompleted(since: Date) async throws -> [ReminderSnapshot] {
        guard let cal = calendar else { throw RemindersError.calendarNotResolved }
        return try await fetch(predicate: store.predicateForCompletedReminders(
            withCompletionDateStarting: since, ending: nil, calendars: [cal]
        ))
    }

    /// Fetch a single live reminder by localId. Returns nil if gone.
    func fetchSnapshot(localId: String) -> ReminderSnapshot? {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else {
            return nil
        }
        return Self.snapshot(from: item)
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
        priority: Int = 0
    ) throws -> ReminderSnapshot {
        guard let cal = calendar else { throw RemindersError.calendarNotResolved }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = cal
        reminder.title = title
        reminder.notes = notes
        reminder.dueDateComponents = dueComponents
        reminder.priority = priority
        try store.save(reminder, commit: true)
        return Self.snapshot(from: reminder)
    }

    /// Write the Logseq backlink into the REMURLAttachment that Reminders.app
    /// displays in its URL field (via the private ReminderKit framework).
    ///
    /// Returns a 3-state result:
    /// - `.written`       — the attachment was written successfully
    /// - `.alreadyCorrect` — the idempotency read matched; no write performed
    /// - `.notFound`      — the reminder no longer exists (stale localId); skip quietly
    /// - `.failed`        — `LRSWriteReminderURLAttachment` returned NO; the caller
    ///                      MUST log this loudly (private API may have changed)
    ///
    /// Detection signal: the bridge write's BOOL (returned by `saveSynchronouslyWithError:`
    /// / guard misses), NOT a post-write read-back. The read-back here is only a
    /// best-effort idempotency skip — a mismatch causes a harmless redundant write,
    /// never a spurious `.failed`.
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

    /// Explicitly set a due date. Separate from updateReminder so nil can't be
    /// misread as "leave unchanged."
    func setDueComponents(localId: String, _ components: DateComponents) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.dueDateComponents = components
        try store.save(item, commit: true)
    }

    /// Explicitly clear a due date. Treats "not found" as success.
    func clearDueComponents(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.dueDateComponents = nil
        try store.save(item, commit: true)
    }

    /// Explicitly set priority. Pass 0 to clear. Treats "not found" as success.
    func setPriority(localId: String, _ priority: Int) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.priority = priority
        try store.save(item, commit: true)
    }

    /// Complete a reminder by localId. Treats "not found" as success.
    func completeReminder(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        item.isCompleted = true
        item.completionDate = Date()
        try store.save(item, commit: true)
    }

    /// Delete a reminder by localId. Treats "not found" as success.
    func deleteReminder(localId: String) throws {
        guard let item = store.calendarItem(withIdentifier: localId) as? EKReminder else { return }
        try store.remove(item, commit: true)
    }

    // MARK: - Snapshot construction (stays inside actor — EKReminder is non-Sendable)

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(
            localId: reminder.calendarItemIdentifier,
            extId: reminder.calendarItemExternalIdentifier ?? "",
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
        case .calendarNotResolved:
            return "Calendar not resolved — call resolveCalendar first."
        case .fetchFailed:
            return "EventKit fetch returned nil."
        case .reminderNotFound(let id):
            return "Reminder not found: \(id)"
        }
    }
}
