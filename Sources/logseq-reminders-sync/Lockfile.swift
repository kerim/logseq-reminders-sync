import Darwin
import Foundation

struct Lockfile {
    let url: URL

    enum LockError: Error, LocalizedError {
        case held(pid: Int32, waited: TimeInterval)
        var errorDescription: String? {
            if case .held(let p, let waited) = self {
                return "A sync started earlier (PID \(p)) was still running after \(Int(waited)) seconds, "
                    + "so this one did not start. That sync is still working and will finish on its own."
            }
            return nil
        }
    }

    /// Takes the lock, waiting for a running sync to finish rather than refusing.
    /// Every Logseq CLI call is time-limited, so a running sync ends well inside
    /// `maxWait`; `onWait` fires once, when waiting starts.
    func acquire(maxWait: TimeInterval = 180, onWait: ((Int32) -> Void)? = nil) throws {
        let deadline = Date().addingTimeInterval(maxWait)
        var announced = false
        while let pid = heldBy() {
            if !announced { onWait?(pid); announced = true }
            guard Date() < deadline else { throw LockError.held(pid: pid, waited: maxWait) }
            usleep(250_000)
        }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try pid.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    /// PID of a live process holding the lock, or nil if it is free or stale.
    private func heldBy() -> Int32? {
        guard let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(s), kill(pid, 0) == 0 else { return nil }
        return pid
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
