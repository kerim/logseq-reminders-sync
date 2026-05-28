import Foundation

public final class StateStore: Sendable {
    private let stateURL: URL

    public init(directory: URL) {
        stateURL = directory.appendingPathComponent("state.json")
    }

    public func load() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else {
            return SyncState()
        }
        return state
    }

    public func save(_ state: SyncState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }
}
