import Foundation

/// Parse an integer build number from a "build-N" tag string.
/// Returns nil for anything that doesn't match exactly.
public func parseBuildNumber(fromTag tag: String) -> Int? {
    guard tag.hasPrefix("build-") else { return nil }
    let suffix = String(tag.dropFirst("build-".count))
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
    return Int(suffix)
}

public enum UpdateCheck {
    /// Returns true when a network check is due.
    /// `force` overrides the interval gate regardless of `lastCheck`.
    public static func shouldCheck(lastCheck: Date?, now: Date,
                                   interval: TimeInterval, force: Bool) -> Bool {
        if force { return true }
        guard let last = lastCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Returns true when the remote build warrants showing a notification.
    /// Conditions: remoteBuild > localBuild AND not already notified for this build.
    public static func shouldNotify(remoteBuild: Int, localBuild: Int,
                                    lastNotifiedBuild: Int?) -> Bool {
        guard remoteBuild > localBuild else { return false }
        return remoteBuild != lastNotifiedBuild
    }
}

public struct UpdateCheckState: Codable {
    public var lastCheck: Date?
    public var lastNotifiedBuild: Int?

    public init(lastCheck: Date? = nil, lastNotifiedBuild: Int? = nil) {
        self.lastCheck = lastCheck
        self.lastNotifiedBuild = lastNotifiedBuild
    }
}

public final class UpdateCheckStore: Sendable {
    private let storeURL: URL

    public init(directory: URL) {
        storeURL = directory.appendingPathComponent("update-check.json")
    }

    public func load() -> UpdateCheckState {
        guard let data = try? Data(contentsOf: storeURL) else { return UpdateCheckState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(UpdateCheckState.self, from: data)) ?? UpdateCheckState()
    }

    public func save(_ state: UpdateCheckState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
