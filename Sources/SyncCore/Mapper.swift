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

    /// Build Logseq block content for an imported reminder. If `url` is a usable
    /// web URL, returns `[escapedTitle](<url>)`; otherwise returns `title` unchanged.
    ///
    /// A `logseq:` URL (our own backlink) is treated as "no user URL" so a
    /// re-import never wraps the backlink. `[`, `]`, `#`, and `\` in the title are
    /// backslash-escaped (backslash first) so the link label can't break the
    /// markdown parser and `#token` isn't parsed as a Logseq tag.
    public static func linkifyImportedTitle(title: String, url: String?) -> String {
        guard let raw = url else { return title }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return title }
        guard !trimmed.lowercased().hasPrefix("logseq:") else { return title }
        guard !title.isEmpty else { return trimmed }

        var label = title
        label = label.replacingOccurrences(of: "\\", with: "\\\\")
        label = label.replacingOccurrences(of: "[", with: "\\[")
        label = label.replacingOccurrences(of: "]", with: "\\]")
        label = label.replacingOccurrences(of: "#", with: "\\#")
        return "[\(label)](\(trimmed))"
    }

    // MARK: - Status mapping

    /// Only "Done" maps to the completed state in Reminders.
    /// "Canceled"/"Cancelled" are now OPEN statuses routed to the Cancelled list.
    public static func logseqStatusIsCompleted(_ status: String) -> Bool {
        status == "Done"
    }

    public static func openStatusToRestore(lastOpenStatus: String?) -> String {
        lastOpenStatus ?? "Doing"
    }

    // MARK: - Bidirectional status merge (pure — no EventKit, unit-testable)

    public enum StatusMergeAction: Equatable {
        /// Both sides agree; write winning status to baseline.
        case converged(String)
        /// Push the given status to the reminder (complete or move list).
        case pushToReminder(String)
        /// Push the given status to Logseq.
        case pushToLogseq(String)
        /// Recurring-completed rotation — the F.2.2 pre-merge guard owns this;
        /// only returned when isRecurring AND action would be pushToLogseq("Done").
        case recurringDeferred
    }

    /// Determine what action to take for the status axis.
    ///
    /// - Parameters:
    ///   - logseqStatus: Current Logseq block status (nil → log+skip, caller handles).
    ///   - effectiveReminderStatus: `"Done"` if completed, else `Config.status(forListId:)`.
    ///     Nil → log+skip, caller handles.
    ///   - lastStatus: Baseline from the most recent sync.
    ///   - logseqMs: Logseq block `updatedAt` epoch ms.
    ///   - reminderMs: Reminder `lastModifiedDate` epoch ms (synthesized `now()` for
    ///     list-moves when EventKit doesn't bump `lastModifiedDate`).
    ///   - isRecurring: Whether the Logseq block has a recurrence rule.
    public static func statusMergeAction(
        logseqStatus: String,
        effectiveReminderStatus: String,
        lastStatus: String,
        logseqMs: Int64,
        reminderMs: Int64?,
        isRecurring: Bool
    ) -> StatusMergeAction {
        // 1. Same-value short-circuit: both sides already agree (even if both differ
        //    from baseline). Return converged so no write / move fires.
        if logseqStatus == effectiveReminderStatus {
            return .converged(logseqStatus)
        }

        let logseqChanged   = logseqStatus           != lastStatus
        let reminderChanged = effectiveReminderStatus != lastStatus

        switch (logseqChanged, reminderChanged) {
        case (false, false):
            // Shouldn't reach here (both equal lastStatus but not each other), but
            // treat as converged defensively.
            return .converged(lastStatus)

        case (true, false):
            // Only Logseq changed.
            return .pushToReminder(logseqStatus)

        case (false, true):
            // Only reminder changed.
            let action = StatusMergeAction.pushToLogseq(effectiveReminderStatus)
            if isRecurring, effectiveReminderStatus == "Done" {
                return .recurringDeferred
            }
            return action

        case (true, true):
            // Both changed. Most-recent-wins; tie → Logseq-wins.
            // A tie MUST perform the pushToReminder write (not a no-op) so that
            // lastStatus is set to logseqStatus and the next pass is .converged.
            let reminderWins = reminderMs.map { $0 > logseqMs } ?? false
            let winner = reminderWins ? effectiveReminderStatus : logseqStatus

            if reminderWins {
                let action = StatusMergeAction.pushToLogseq(winner)
                if isRecurring, winner == "Done" { return .recurringDeferred }
                return action
            } else {
                // Logseq wins (or tie)
                return .pushToReminder(winner)
            }
        }
    }

    // MARK: - Notes building

    /// Build the notes string for a mirror reminder: pure plain-text child
    /// lines joined by newlines. Empty for childless blocks.
    public static func buildNotesString(childTitlesPlainText: [String]) -> String {
        childTitlesPlainText.joined(separator: "\n")
    }

    // MARK: - Note import (Reminders → Logseq, one-way)

    /// Split an Apple Reminders note body into paragraph blocks for one-way note import.
    /// Each newline-delimited paragraph is trimmed; blank / whitespace-only lines are
    /// dropped. Handles `\n`, `\r\n`, and bare `\r`. Returns `[]` for nil / empty /
    /// whitespace-only input.
    public static func splitNoteParagraphs(_ notes: String?) -> [String] {
        guard let notes else { return [] }
        return notes
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
    }

    // MARK: - EDN escaping

    /// Escape a Swift string for use inside an EDN/Datascript double-quoted string literal.
    /// Escapes `\` then `"` only — other bytes (including newlines) pass through unescaped.
    /// Note bodies are newline-free per `splitNoteParagraphs`; titles are single-line.
    public static func ednString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Logseq deep link

    /// Build a Logseq deep link to a block: `logseq://graph/<graph>?block-id=<uuid>`.
    /// Opens the source task in the Logseq app (desktop and mobile) — used as the
    /// reminder's URL so a synced reminder can jump back to its origin block.
    ///
    /// `URLComponents` percent-encodes the graph-name path segment (e.g. a space
    /// becomes `%20`). Note: `/`, `?`, and `#` in a graph name are NOT path-encoded,
    /// but those aren't valid Logseq graph names, so this is acceptable.
    public static func logseqDeepLink(graph: String, blockUUID: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = "logseq"
        comps.host = "graph"
        comps.path = "/" + graph          // leading "/" is required when host is set
        comps.queryItems = [URLQueryItem(name: "block-id", value: blockUUID)]
        return comps.url
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
        for line in notes.components(separatedBy: "\n") where line.hasPrefix(prefix) {
            let val = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return val.isEmpty ? nil : val
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

    // MARK: - Date 3-way merge (pure — no EventKit, unit-testable)

    /// A due date paired with the Logseq field it occupies (`scheduled`/`deadline`).
    /// These two always travel together — a value and the label that says which Logseq
    /// field it lives in — so they're modeled as one input, not two. `ms == nil` means
    /// "no date" (and `source` is then nil). Reminders have no field dimension, so the
    /// reminder side of a merge is a bare `Int64?`, not a `SourcedDate`.
    public struct SourcedDate: Equatable {
        public let ms: Int64?
        public let source: LogseqDateField?
        public init(ms: Int64?, source: LogseqDateField?) {
            self.ms = ms
            self.source = source
        }
    }

    public enum DateMergeAction: Equatable {
        /// Both sides already agree with the baseline; no write, no baseline change.
        case noChange
        /// First-time baseline where the two sides already agree (or both empty):
        /// record the baseline without writing to either side.
        case recordBaseline(ms: Int64?, source: LogseqDateField?)
        /// Write `ms` to the reminder (`nil` = clear its due date); executor sets baseline.
        case pushToReminder(ms: Int64?, source: LogseqDateField?)
        /// Write `ms` to Logseq via `source` (`nil` = clear that field); executor sets baseline.
        case pushToLogseq(ms: Int64?, source: LogseqDateField?)
    }

    /// Decide the action for the date axis. Pure: the SyncEngine executor performs the
    /// writes and applies the returned baseline. Mirrors `statusMergeAction`.
    ///
    /// At first-time baseline (`baseline.ms == nil`) the empty side is SEEDED rather than
    /// left blank. Otherwise the next pass mistakes an empty side for a deliberate
    /// "date cleared" edit and wipes the populated side (the reported data-loss bug, plus
    /// its mirror where only the reminder held a date). On genuine first-enable divergence
    /// Logseq wins — it is the user's source of truth.
    ///
    /// - Parameters:
    ///   - logseq: Logseq's current date + field (deadline preferred over scheduled).
    ///   - reminderMs: the reminder's current due date in epoch ms, nil if none.
    ///   - baseline: date + field recorded at the last sync (`ms == nil` = not yet established).
    ///   - logseqUpdatedMs: Logseq block `updatedAt` — the conflict tie-break operand.
    ///   - reminderUpdatedMs: reminder pre-write `lastModified` ms — the conflict operand.
    public static func dateMergeAction(
        logseq: SourcedDate,
        reminderMs: Int64?,
        baseline: SourcedDate,
        logseqUpdatedMs: Int64,
        reminderUpdatedMs: Int64?
    ) -> DateMergeAction {
        // First-time baseline establishment: seed the empty side so both converge.
        if baseline.ms == nil {
            if let l = logseq.ms {
                // Logseq is authoritative at first baseline (Logseq-wins on divergence).
                return reminderMs == l
                    ? .recordBaseline(ms: l, source: logseq.source)
                    : .pushToReminder(ms: l, source: logseq.source)
            } else if let r = reminderMs {
                // Only the reminder has a date — seed Logseq (Step-7 adopt convention).
                return .pushToLogseq(ms: r, source: .scheduled)
            } else {
                return .noChange
            }
        }

        let logseqChanged   = logseq.ms != baseline.ms
        let reminderChanged = reminderMs != baseline.ms

        switch (logseqChanged, reminderChanged) {
        case (false, false):
            return .noChange
        case (true, false):
            return .pushToReminder(ms: logseq.ms, source: logseq.source)
        case (false, true):
            return .pushToLogseq(ms: reminderMs, source: baseline.source ?? .scheduled)
        case (true, true):
            // Both changed — most-recent-wins; tie (>=) → Logseq wins.
            if logseqUpdatedMs >= (reminderUpdatedMs ?? 0) {
                return .pushToReminder(ms: logseq.ms, source: logseq.source)
            } else {
                return .pushToLogseq(ms: reminderMs, source: baseline.source ?? .scheduled)
            }
        }
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
