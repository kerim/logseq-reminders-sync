import Foundation

// MARK: - LogseqDateField

public enum LogseqDateField: String, Codable, Sendable {
    case deadline = "deadline"
    case scheduled = "scheduled"
}

// MARK: - SyncPair

public struct SyncPair: Codable, Sendable {
    public var logseqUUID: String
    public var reminderLocalId: String
    public var reminderExtId: String
    public var lastStatus: String
    /// Last OPEN status — restored when un-completing from Reminders. Never set to Done/Canceled.
    public var lastOpenStatus: String
    public var lastCompleted: Bool
    public var lastLogseqUpdated: Int64
    public var lastReminderMod: Int64?
    public var lastTitle: String
    public var lastNotesHash: String
    /// Last synced due-date as ms since epoch (UTC). nil until first date sync.
    public var lastDueDateMs: Int64?
    /// Which Logseq field owns the due-date for this pair.
    public var lastDueSource: LogseqDateField?
    /// Set when a recurring block's reminder was completed; cleared when rotation fires.
    public var pendingRotation: Bool
    /// Counts passes where rotation was pending but conditions weren't met.
    public var rotationAttempts: Int
    /// Last observed Logseq priority, post-Low-filter (so `.low` is stored as `nil`).
    public var lastPriority: LogseqPriority?

    public init(
        logseqUUID: String,
        reminderLocalId: String,
        reminderExtId: String,
        lastStatus: String,
        lastOpenStatus: String,
        lastCompleted: Bool,
        lastLogseqUpdated: Int64,
        lastReminderMod: Int64?,
        lastTitle: String,
        lastNotesHash: String,
        lastDueDateMs: Int64? = nil,
        lastDueSource: LogseqDateField? = nil,
        pendingRotation: Bool = false,
        rotationAttempts: Int = 0,
        lastPriority: LogseqPriority? = nil
    ) {
        self.logseqUUID = logseqUUID
        self.reminderLocalId = reminderLocalId
        self.reminderExtId = reminderExtId
        self.lastStatus = lastStatus
        self.lastOpenStatus = lastOpenStatus
        self.lastCompleted = lastCompleted
        self.lastLogseqUpdated = lastLogseqUpdated
        self.lastReminderMod = lastReminderMod
        self.lastTitle = lastTitle
        self.lastNotesHash = lastNotesHash
        self.lastDueDateMs = lastDueDateMs
        self.lastDueSource = lastDueSource
        self.pendingRotation = pendingRotation
        self.rotationAttempts = rotationAttempts
        self.lastPriority = lastPriority
    }

    // MARK: - Codable (explicit for backward-compat: new fields use decodeIfPresent)

    private enum CodingKeys: String, CodingKey {
        case logseqUUID, reminderLocalId, reminderExtId
        case lastStatus, lastOpenStatus, lastCompleted
        case lastLogseqUpdated, lastReminderMod
        case lastTitle, lastNotesHash
        case lastDueDateMs, lastDueSource
        case pendingRotation, rotationAttempts
        case lastPriority
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        logseqUUID        = try c.decode(String.self,          forKey: .logseqUUID)
        reminderLocalId   = try c.decode(String.self,          forKey: .reminderLocalId)
        reminderExtId     = try c.decode(String.self,          forKey: .reminderExtId)
        lastStatus        = try c.decode(String.self,          forKey: .lastStatus)
        lastOpenStatus    = try c.decode(String.self,          forKey: .lastOpenStatus)
        lastCompleted     = try c.decode(Bool.self,            forKey: .lastCompleted)
        lastLogseqUpdated = try c.decode(Int64.self,           forKey: .lastLogseqUpdated)
        lastReminderMod   = try c.decodeIfPresent(Int64.self,  forKey: .lastReminderMod)
        lastTitle         = try c.decode(String.self,          forKey: .lastTitle)
        lastNotesHash     = try c.decode(String.self,          forKey: .lastNotesHash)
        // New fields — nil/false defaults for existing state.json files
        lastDueDateMs     = try c.decodeIfPresent(Int64.self,            forKey: .lastDueDateMs)
        lastDueSource     = try c.decodeIfPresent(LogseqDateField.self,  forKey: .lastDueSource)
        pendingRotation   = try c.decodeIfPresent(Bool.self,             forKey: .pendingRotation)   ?? false
        rotationAttempts  = try c.decodeIfPresent(Int.self,              forKey: .rotationAttempts)  ?? 0
        // Tolerant decode: a future "Critical" rawValue would otherwise throw
        // dataCorrupted (decodeIfPresent doesn't swallow rawValue failures) and
        // tank the whole SyncPair decode. try? also swallows type-mismatch — accepted
        // as defense-in-depth since state.json is local and single-writer.
        lastPriority      = (try? c.decodeIfPresent(LogseqPriority.self, forKey: .lastPriority)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(logseqUUID,        forKey: .logseqUUID)
        try c.encode(reminderLocalId,   forKey: .reminderLocalId)
        try c.encode(reminderExtId,     forKey: .reminderExtId)
        try c.encode(lastStatus,        forKey: .lastStatus)
        try c.encode(lastOpenStatus,    forKey: .lastOpenStatus)
        try c.encode(lastCompleted,     forKey: .lastCompleted)
        try c.encode(lastLogseqUpdated, forKey: .lastLogseqUpdated)
        try c.encodeIfPresent(lastReminderMod, forKey: .lastReminderMod)
        try c.encode(lastTitle,         forKey: .lastTitle)
        try c.encode(lastNotesHash,     forKey: .lastNotesHash)
        try c.encodeIfPresent(lastDueDateMs,  forKey: .lastDueDateMs)
        try c.encodeIfPresent(lastDueSource,  forKey: .lastDueSource)
        try c.encode(pendingRotation,   forKey: .pendingRotation)
        try c.encode(rotationAttempts,  forKey: .rotationAttempts)
        try c.encodeIfPresent(lastPriority, forKey: .lastPriority)
    }
}

// MARK: - CaptureRecord

public struct CaptureRecord: Codable, Sendable {
    public var reminderLocalId: String
    public var reminderExtId: String
    public var journalBlockUUID: String

    public init(reminderLocalId: String, reminderExtId: String, journalBlockUUID: String) {
        self.reminderLocalId = reminderLocalId
        self.reminderExtId = reminderExtId
        self.journalBlockUUID = journalBlockUUID
    }
}

// MARK: - SyncState

public struct SyncState: Codable, Sendable {
    public var pairs: [SyncPair]
    public var captures: [CaptureRecord]
    public var lastRunDate: Date?
    /// Reminder extIds for completed recurring cycles. Future syncs skip these
    /// during classification so the completed-as-history reminder isn't re-captured
    /// as a fresh Logseq block.
    public var archivedExtIds: [String]

    public init() {
        self.pairs = []
        self.captures = []
        self.lastRunDate = nil
        self.archivedExtIds = []
    }

    private enum CodingKeys: String, CodingKey {
        case pairs, captures, lastRunDate, archivedExtIds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairs          = try c.decode([SyncPair].self,        forKey: .pairs)
        captures       = try c.decode([CaptureRecord].self,   forKey: .captures)
        lastRunDate    = try c.decodeIfPresent(Date.self,     forKey: .lastRunDate)
        archivedExtIds = try c.decodeIfPresent([String].self, forKey: .archivedExtIds) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pairs,                forKey: .pairs)
        try c.encode(captures,             forKey: .captures)
        try c.encodeIfPresent(lastRunDate, forKey: .lastRunDate)
        try c.encode(archivedExtIds,       forKey: .archivedExtIds)
    }
}
