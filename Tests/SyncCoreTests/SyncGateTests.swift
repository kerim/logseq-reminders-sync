import Testing
import Foundation
@testable import SyncCore

@Suite("SyncGate")
struct SyncGateTests {

    private let baseline = ChangeSignals(
        logseqMaxTx: 1000,
        remindersListCounts: ["Todo": 3, "Doing": 1],
        remindersMaxModifiedMs: 1_700_000_000_000
    )

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let forceAfter: TimeInterval = 3600   // 60 min

    /// lastRun just before `now`, well inside the force window.
    private var recentRun: Date { now.addingTimeInterval(-60) }

    @Test("nil cache forces a run")
    func nilCacheRuns() {
        let d = SyncGate.decision(cached: nil, current: baseline,
                                  lastRun: recentRun, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }

    @Test("nil lastRun forces a run")
    func nilLastRunRuns() {
        let d = SyncGate.decision(cached: baseline, current: baseline,
                                  lastRun: nil, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }

    @Test("Identical signals within the force window skip")
    func identicalSkips() {
        let d = SyncGate.decision(cached: baseline, current: baseline,
                                  lastRun: recentRun, now: now, forceAfter: forceAfter)
        #expect(d == .skip)
    }

    @Test("Changed Logseq tx forces a run")
    func txChangeRuns() {
        var current = baseline
        current.logseqMaxTx = 1001
        let d = SyncGate.decision(cached: baseline, current: current,
                                  lastRun: recentRun, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }

    @Test("Changed per-list count forces a run (e.g. a managed→managed move)")
    func listCountChangeRuns() {
        var current = baseline
        current.remindersListCounts = ["Todo": 2, "Doing": 2]   // total unchanged, distribution shifted
        let d = SyncGate.decision(cached: baseline, current: current,
                                  lastRun: recentRun, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }

    @Test("Changed max-modified forces a run")
    func maxModChangeRuns() {
        var current = baseline
        current.remindersMaxModifiedMs = 1_700_000_000_001
        let d = SyncGate.decision(cached: baseline, current: current,
                                  lastRun: recentRun, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }

    @Test("Stale last run forces a run even when signals match")
    func staleRunForcesRun() {
        let stale = now.addingTimeInterval(-(forceAfter + 1))
        let d = SyncGate.decision(cached: baseline, current: baseline,
                                  lastRun: stale, now: now, forceAfter: forceAfter)
        #expect(d == .run)
    }
}
