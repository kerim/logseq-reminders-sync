import Darwin
import Foundation

struct Lockfile {
    let url: URL

    enum LockError: Error, LocalizedError {
        case held(pid: Int32)
        var errorDescription: String? {
            if case .held(let p) = self { return "Another sync is running (PID \(p))" }
            return nil
        }
    }

    func acquire() throws {
        if let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(s) {
            if kill(pid, 0) == 0 { throw LockError.held(pid: pid) }
        }
        let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
        try pid.data(using: .utf8)!.write(to: url, options: .atomic)
    }

    func release() {
        try? FileManager.default.removeItem(at: url)
    }
}
