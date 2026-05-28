import Foundation

public struct ReminderSnapshot: Sendable, Equatable {
    public let localId: String
    public let extId: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let completionDate: Date?
    public let lastModified: Date?
    public let dueComponents: DateComponents?

    public init(
        localId: String,
        extId: String,
        title: String,
        notes: String?,
        isCompleted: Bool,
        completionDate: Date?,
        lastModified: Date?,
        dueComponents: DateComponents?
    ) {
        self.localId = localId
        self.extId = extId
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.completionDate = completionDate
        self.lastModified = lastModified
        self.dueComponents = dueComponents
    }
}
