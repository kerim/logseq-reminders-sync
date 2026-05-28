import Foundation

public struct LogseqBlock: Sendable {
    public let uuid: String
    public let title: String
    public let updatedAt: Int64
    public let status: String?
    public let deadline: Int?
    public let scheduled: Int?
    public let isRecurring: Bool

    public init(
        uuid: String,
        title: String,
        updatedAt: Int64,
        status: String?,
        deadline: Int?,
        scheduled: Int?,
        isRecurring: Bool = false
    ) {
        self.uuid = uuid
        self.title = title
        self.updatedAt = updatedAt
        self.status = status
        self.deadline = deadline
        self.scheduled = scheduled
        self.isRecurring = isRecurring
    }
}

public enum LogseqStatus: String, CaseIterable {
    case doing = "Doing"
    case todo = "Todo"
    case backlog = "Backlog"
    case inReview = "In Review"
    case done = "Done"
    case canceled = "Canceled"

    public var isOpen: Bool {
        switch self {
        case .doing, .todo, .backlog, .inReview: return true
        case .done, .canceled: return false
        }
    }

    public init?(rawTitle: String) {
        if let found = LogseqStatus.allCases.first(where: { $0.rawValue == rawTitle }) {
            self = found
        } else {
            return nil
        }
    }
}
