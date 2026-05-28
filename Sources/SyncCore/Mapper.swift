import CryptoKit
import Foundation

public enum Mapper {

    // MARK: - Back-compat constants (BUILD ≤8 footer formats)

    public static let mirrorFooterKey = "logseq-id"
    public static let captureFooterKey = "logseq-captured"

    // MARK: - Title / text transforms

    /// Strip Logseq-specific markup that isn't covered by markdown parsing:
    /// - `[[Page]]` → `Page` (wrapper strip; UUID page-refs should be resolved
    ///   beforehand via `resolvePageRefs(_:titles:)`)
    /// - `#tag` → `tag`
    /// - `((uuid))` → `` (block refs removed)
    public static func transformTitle(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<![^\s])#(\S+)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\(\([0-9a-f-]{36}\)\)"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Convert remaining standard markdown to plain text via Foundation's
    /// markdown parser (macOS 12+). Strips `**bold**`, `*italic*`, `` `code` ``,
    /// `[label](url)` → `label`, etc. Falls back to the input string if parsing
    /// fails (e.g. unbalanced syntax that confuses the parser).
    public static func plainTextify(_ text: String) -> String {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        if let attr = try? AttributedString(markdown: text, options: options) {
            return String(attr.characters)
        }
        return text
    }

    /// Find all UUIDs referenced via `[[uuid]]` syntax in the given text.
    /// Returns lowercase UUID strings (the regex matches Logseq's canonical
    /// form: 8-4-4-4-12 lowercase hex).
    public static func extractPageRefUUIDs(_ text: String) -> [String] {
        let pattern = #"\[\[([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            match.numberOfRanges > 1 ? ns.substring(with: match.range(at: 1)) : nil
        }
    }

    /// Replace each `[[uuid]]` reference in the text with the resolved page
    /// title from `titles`. UUIDs absent from the map are left as `[[uuid]]`
    /// (downstream `transformTitle` will at least strip the brackets).
    public static func resolvePageRefs(_ text: String, titles: [String: String]) -> String {
        var result = text
        for (uuid, title) in titles {
            result = result.replacingOccurrences(of: "[[\(uuid)]]", with: title)
        }
        return result
    }

    /// Full pipeline for a single line of Logseq text:
    /// resolve UUID page refs → strip Logseq markup → strip remaining markdown.
    public static func plainText(_ raw: String, pageTitles: [String: String]) -> String {
        let resolved = resolvePageRefs(raw, titles: pageTitles)
        let stripped = transformTitle(resolved)
        return plainTextify(stripped)
    }

    // MARK: - Status mapping

    public static func logseqStatusIsCompleted(_ status: String) -> Bool {
        status == "Done" || status == "Canceled" || status == "Cancelled"
    }

    public static func openStatusToRestore(lastOpenStatus: String?) -> String {
        lastOpenStatus ?? "Doing"
    }

    // MARK: - Notes building

    /// Build the notes string for a mirror reminder: pure plain-text child
    /// lines joined by newlines. Empty for childless blocks.
    public static func buildNotesString(childTitlesPlainText: [String]) -> String {
        childTitlesPlainText.joined(separator: "\n")
    }

    // MARK: - Back-compat extractors (recognize BUILD ≤8 footer formats)

    public static func extractMirrorUUID(from notes: String?) -> String? {
        extractFooterValue(key: mirrorFooterKey, from: notes)
    }

    public static func extractCaptureUUID(from notes: String?) -> String? {
        extractFooterValue(key: captureFooterKey, from: notes)
    }

    private static func extractFooterValue(key: String, from notes: String?) -> String? {
        guard let notes else { return nil }
        let prefix = "\(key): "
        for line in notes.components(separatedBy: "\n") {
            if line.hasPrefix(prefix) {
                let val = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return val.isEmpty ? nil : val
            }
        }
        return nil
    }

    // MARK: - Hash

    public static func hashNotes(_ notes: String) -> String {
        let digest = SHA256.hash(data: Data(notes.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Date helpers

    /// UTC calendar — retained for tests that want TZ-independent round-trips.
    /// Production code uses `Calendar.current` (see below) to match Logseq's
    /// own behavior of storing user-picked dates as midnight in the user's
    /// local timezone.
    public static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()

    /// Convert an epoch-ms timestamp from Logseq into DateComponents for Apple
    /// Reminders, using the user's local timezone by default. Logseq stores a
    /// user-picked date as midnight in that local zone, so extracting in local
    /// gets the calendar day the user actually picked.
    ///
    /// Midnight heuristic: if the rendered local hour/minute are both zero,
    /// the value is a date-only entry and we omit hour/minute from the result
    /// so Apple Reminders treats it as an all-day reminder. Otherwise we keep
    /// hour/minute (the user picked a specific time-of-day in Logseq).
    public static func epochMsToDueComponents(
        _ ms: Int64,
        calendar: Calendar = .current
    ) -> DateComponents {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let full = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if (full.hour ?? 0) == 0 && (full.minute ?? 0) == 0 {
            // Date-only: drop hour/minute so Apple Reminders renders as all-day.
            var dateOnly = DateComponents()
            dateOnly.year = full.year
            dateOnly.month = full.month
            dateOnly.day = full.day
            return dateOnly
        }
        return full
    }

    /// Convert DateComponents back to epoch ms in the user's local timezone.
    /// Returns nil if the components are too incomplete for `Calendar.date(from:)`
    /// (e.g., year+month but no day). Never silently invents a date.
    public static func dueComponentsToEpochMs(
        _ components: DateComponents,
        calendar: Calendar = .current
    ) -> Int64? {
        guard let date = calendar.date(from: components) else { return nil }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    /// Determine which Logseq date field is present. `deadline` wins when both
    /// are set because it represents the harder commitment.
    public static func preferredDateField(deadline: Int?, scheduled: Int?) -> LogseqDateField? {
        if deadline != nil { return .deadline }
        if scheduled != nil { return .scheduled }
        return nil
    }

    // MARK: - Priority mapping
    //
    // Logseq has 4 priority levels (Urgent/High/Medium/Low); Apple Reminders
    // has 3 effective levels via RFC 5545 ints (1=High, 5=Medium, 9=Low) plus 0
    // for "no priority". The mapping shifts one step down: Urgent→High,
    // High→Medium, Medium→Low. Logseq "Low" is treated as "no priority"
    // (normalized via LogseqPriority.forSync) — Low never appears on the
    // reverse path.

    public static func logseqPriorityToReminder(_ priority: LogseqPriority?) -> Int {
        guard let p = priority?.forSync else { return 0 }
        switch p {
        case .urgent: return 1
        case .high:   return 5
        case .medium: return 9
        case .low:    return 0  // unreachable after forSync
        }
    }

    /// Bucketed reverse mapping — Apple's int range collapses to the three
    /// non-Low Logseq levels (matching what Apple's UI displays). Intermediate
    /// values from third-party editors (e.g. priority 7) snap to the bucket
    /// they belong in (5–8 → .high).
    public static func reminderPriorityToLogseq(_ priority: Int) -> LogseqPriority? {
        switch priority {
        case 1...4: return .urgent
        case 5...8: return .high
        case 9:     return .medium
        default:    return nil    // 0 or out-of-range
        }
    }

}
