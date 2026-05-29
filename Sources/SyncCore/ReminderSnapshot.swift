import Foundation

public struct ReminderSnapshot: Sendable, Equatable {
    public let localId: String
    public let extId: String
    /// The calendar identifier of the list this reminder belongs to.
    /// Used by the engine to derive `effectiveReminderStatus` via `Config.status(forListId:)`.
    public let listId: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let completionDate: Date?
    public let lastModified: Date?
    public let dueComponents: DateComponents?
    public let priority: Int

    public init(
        localId: String,
        extId: String,
        listId: String,
        title: String,
        notes: String?,
        isCompleted: Bool,
        completionDate: Date?,
        lastModified: Date?,
        dueComponents: DateComponents?,
        priority: Int = 0
    ) {
        self.localId = localId
        self.extId = extId
        self.listId = listId
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.lastModified = lastModified
        self.dueComponents = dueComponents
        self.priority = priority
    }
}
