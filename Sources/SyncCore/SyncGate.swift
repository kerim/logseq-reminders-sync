import Foundation

// MARK: - Smart-polling gate (pure, host-free)
//
// Decides whether a sync pass should run or be skipped, by comparing cheap
// change-signals against the cache from the last full run. Lives in SyncCore (no
// EventKit / Process) so it is unit-testable in isolation.
//
// Governing principle: over-trigger, never under-trigger. A false "changed" just
// runs a normal sync (harmless); a false "unchanged" silently drops a sync. So a
// nil cache, a missing last-run timestamp, or a stale last run all force `.run`.

/// The two cheap change-signals: a Logseq graph-wide datascript transaction id
/// (bumps on any datom write) and the Reminders side as per-list incomplete counts
/// plus the max last-modified timestamp (epoch ms) across incomplete + recently
/// completed reminders.
public struct ChangeSignals: Equatable, Sendable {
    public var logseqMaxTx: Int64
    public var remindersListCounts: [String: Int]
    public var remindersMaxModifiedMs: Int64

    public init(logseqMaxTx: Int64, remindersListCounts: [String: Int], remindersMaxModifiedMs: Int64) {
        self.logseqMaxTx = logseqMaxTx
        self.remindersListCounts = remindersListCounts
        self.remindersMaxModifiedMs = remindersMaxModifiedMs
    }
}

public enum GateDecision: Equatable, Sendable {
    case run
    case skip
}

public enum SyncGate {
    /// Decide whether to run a full sync.
    ///
    /// - `cached == nil` (no usable cache) → `.run`.
    /// - `lastRun == nil`, or more than `forceAfter` has elapsed → `.run` (periodic
    ///   safety-net / backstop for the bounded under-trigger windows).
    /// - signals differ from the cache → `.run`.
    /// - otherwise → `.skip`.
    public static func decision(
        cached: ChangeSignals?,
        current: ChangeSignals,
        lastRun: Date?,
        now: Date,
        forceAfter: TimeInterval
    ) -> GateDecision {
        guard let cached else { return .run }
        guard let lastRun else { return .run }
        if now.timeIntervalSince(lastRun) > forceAfter { return .run }
        return current == cached ? .skip : .run
    }
}
