import Foundation

struct RunLogger {
    private let logURL: URL?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init(logDirectory: URL?) {
        guard let dir = logDirectory else { self.logURL = nil; return }
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let name = String(format: "%04d-%02d-%02d.log", comps.year!, comps.month!, comps.day!)
        self.logURL = dir.appendingPathComponent(name)
    }

    func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)"
        print(line)
        guard let url = logURL else { return }
        let bytes = (line + "\n").data(using: .utf8) ?? Data()
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            fh.seekToEndOfFile()
            fh.write(bytes)
        } else {
            try? bytes.write(to: url)
        }
    }
}
