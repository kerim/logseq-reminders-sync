import Testing
import Foundation
@testable import SyncCore

@Suite("UpdateCheck")
struct UpdateCheckTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let interval: TimeInterval = 86_400   // 24h

    // MARK: parseBuildNumber

    @Test("build-39 parses to 39")
    func parseBuild39() {
        #expect(parseBuildNumber(fromTag: "build-39") == 39)
    }

    @Test("build-0 parses to 0")
    func parseBuild0() {
        #expect(parseBuildNumber(fromTag: "build-0") == 0)
    }

    @Test("semver tag returns nil")
    func parseSemver() {
        #expect(parseBuildNumber(fromTag: "v1.2.0") == nil)
    }

    @Test("bare build- suffix returns nil")
    func parseBarePrefix() {
        #expect(parseBuildNumber(fromTag: "build-") == nil)
    }

    @Test("trailing non-digit returns nil")
    func parseTrailingChar() {
        #expect(parseBuildNumber(fromTag: "build-39x") == nil)
    }

    @Test("plain number returns nil")
    func parsePlainNumber() {
        #expect(parseBuildNumber(fromTag: "39") == nil)
    }

    @Test("empty string returns nil")
    func parseEmpty() {
        #expect(parseBuildNumber(fromTag: "") == nil)
    }

    // MARK: shouldNotify

    @Test("newer remote triggers notification")
    func notifyWhenNewer() {
        #expect(UpdateCheck.shouldNotify(remoteBuild: 40, localBuild: 39, lastNotifiedBuild: nil))
    }

    @Test("same build does not notify")
    func noNotifyWhenSame() {
        #expect(!UpdateCheck.shouldNotify(remoteBuild: 39, localBuild: 39, lastNotifiedBuild: nil))
    }

    @Test("older remote does not notify")
    func noNotifyWhenOlder() {
        #expect(!UpdateCheck.shouldNotify(remoteBuild: 38, localBuild: 39, lastNotifiedBuild: nil))
    }

    @Test("already notified for this build suppresses notification")
    func noNotifyWhenAlreadyNotified() {
        #expect(!UpdateCheck.shouldNotify(remoteBuild: 40, localBuild: 39, lastNotifiedBuild: 40))
    }

    @Test("newer build after a previous notification fires again")
    func notifyForNewBuildAfterPrevious() {
        #expect(UpdateCheck.shouldNotify(remoteBuild: 41, localBuild: 39, lastNotifiedBuild: 40))
    }

    // MARK: shouldCheck

    @Test("nil lastCheck triggers a check")
    func checkWhenNilLastCheck() {
        #expect(UpdateCheck.shouldCheck(lastCheck: nil, now: now, interval: interval, force: false))
    }

    @Test("check is due when interval elapsed")
    func checkWhenDue() {
        let last = now.addingTimeInterval(-(interval + 1))
        #expect(UpdateCheck.shouldCheck(lastCheck: last, now: now, interval: interval, force: false))
    }

    @Test("check is skipped when interval not yet elapsed")
    func skipWhenNotDue() {
        let last = now.addingTimeInterval(-(interval - 60))
        #expect(!UpdateCheck.shouldCheck(lastCheck: last, now: now, interval: interval, force: false))
    }

    @Test("force bypasses interval gate")
    func forceOverridesInterval() {
        let last = now.addingTimeInterval(-60)   // very recent
        #expect(UpdateCheck.shouldCheck(lastCheck: last, now: now, interval: interval, force: true))
    }

    // MARK: UpdateCheckStore round-trip

    @Test("store round-trip preserves state")
    func storeRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = UpdateCheckStore(directory: dir)
        var state = UpdateCheckState()
        state.lastCheck = Date(timeIntervalSince1970: 1_800_000_000)
        state.lastNotifiedBuild = 42
        store.save(state)

        let loaded = store.load()
        #expect(loaded.lastNotifiedBuild == 42)
        #expect(abs((loaded.lastCheck?.timeIntervalSince1970 ?? 0) - 1_800_000_000) < 1)
    }

    @Test("missing file returns empty state")
    func emptyStateOnMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = UpdateCheckStore(directory: dir)
        let state = store.load()
        #expect(state.lastCheck == nil)
        #expect(state.lastNotifiedBuild == nil)
    }
}
