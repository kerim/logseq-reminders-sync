import Foundation
import SyncCore

struct PropertyIdents {
    let reminderId: String
    let capturedReminderId: String
    let deadline: String
    let scheduled: String
    let repeated: String
}

/// Where an adopted capture task is placed on the journal page.
enum CaptureTarget {
    /// Nested under a named sub-block (e.g. "Inbox"). Created if absent.
    case inboxBlock(uuid: String)
    /// Directly on the journal page (top-level block).
    case journalPage(name: String)

    /// The `logseq upsert block` target flag for this destination. Centralized here
    /// so every create path (capture task, note import) renders args identically.
    var cliArgs: [String] {
        switch self {
        case .inboxBlock(let uuid):  return ["--target-uuid", uuid]
        case .journalPage(let name): return ["--target-page", name]
        }
    }
}

struct LogseqClient {
    let cliPath: String
    let graph: String
    let logger: RunLogger?
    private(set) var propertyIdents: PropertyIdents?

    init(cliPath: String, graph: String, logger: RunLogger? = nil) {
        self.cliPath = cliPath
        self.graph = graph
        self.logger = logger
    }

    // MARK: - Bootstrap

    mutating func bootstrap() async throws {
        for name in ["reminder-id", "captured-reminder-id"] {
            _ = try await run([
                "upsert", "property", "-g", graph,
                "--name", name, "--type", "default",
                "--cardinality", "one", "--public", "--output", "json"
            ])
        }
        let remId  = try await resolvePropertyIdent(name: "reminder-id")
        let capId  = try await resolvePropertyIdent(name: "captured-reminder-id")
        // Built-in Logseq DB idents — these are constants in the schema but we
        // resolve them through the DB to avoid hardcoding string literals.
        let deadlineIdent   = try await resolveBuiltinIdent("logseq.property/deadline")
        let scheduledIdent  = try await resolveBuiltinIdent("logseq.property/scheduled")
        let repeatedIdent   = try await resolveBuiltinIdent("logseq.property.repeat/repeated?")
        propertyIdents = PropertyIdents(
            reminderId: remId,
            capturedReminderId: capId,
            deadline: deadlineIdent,
            scheduled: scheduledIdent,
            repeated: repeatedIdent
        )
    }

    private func resolveBuiltinIdent(_ ident: String) async throws -> String {
        let result = try await query(
            "[:find ?ident :where [?e :db/ident :\(ident)] [?e :db/ident ?ident]]"
        )
        guard let rows = result as? [[Any]], let first = rows.first,
              let found = first.first as? String else {
            // Ident not in this graph — return the ident itself as a fallback.
            return ident
        }
        return found
    }

    private func resolvePropertyIdent(name: String) async throws -> String {
        let result = try await query(
            "[:find ?ident :where [?p :block/title \"\(name)\"] [?p :db/ident ?ident]]"
        )
        guard let rows = result as? [[Any]], let first = rows.first,
              let ident = first.first as? String else {
            throw LogseqError.propertyNotFound(name)
        }
        return ident
    }

    // MARK: - Graph listing (for setup / switch-graph pickers)

    /// List available Logseq graph names. Does not use `graph` (a throwaway client with
    /// any graph value works). Parses the verified `data.graphs` envelope — note this
    /// differs from the `data.result` envelope `query(_:)` parses.
    func listGraphs() async throws -> [String] {
        let result = try await run(["graph", "list", "--output", "json"])
        guard let dict = result as? [String: Any],
              let data = dict["data"] as? [String: Any],
              let graphs = data["graphs"] as? [String] else {
            throw LogseqError.unexpectedShape("graph list: \(String(describing: result).prefix(200))")
        }
        return graphs
    }

    // MARK: - Reading tasks

    /// Fetch all tasks with priority Urgent, High, or Medium — regardless of status.
    /// Returns every status (including Done and Canceled) so the engine can retain
    /// still-prioritized closed tasks. Status is nil when absent (engine handles it
    /// explicitly; never defaults to "Doing").
    func fetchPrioritizedTasks() async throws -> [LogseqBlock] {
        struct TaskMeta {
            var title: String
            var updatedAt: Int64
            var status: String?
            var deadline: Int?
            var scheduled: Int?
            var priority: LogseqPriority?
        }

        // Base: all blocks with priority ∈ {Urgent, High, Medium}, any status.
        // Selection is by the priority ref alone, independent of status.
        let baseRows = try await query("""
            [:find ?uuid ?title ?updated ?prio-title
             :where [?b :logseq.property/priority ?p] [?p :block/title ?prio-title]
                    [(contains? #{"Urgent" "High" "Medium"} ?prio-title)]
                    [?b :block/uuid ?uuid] [?b :block/title ?title]
                    [?b :block/updated-at ?updated]]
            """)

        var byUUID: [String: TaskMeta] = [:]
        if let rows = baseRows as? [[Any]] {
            for row in rows {
                guard let uuid = row[0] as? String,
                      let title = row[1] as? String,
                      let updated = jsonInt64(row[2]),
                      let prioTitle = row[3] as? String else { continue }
                let prio = LogseqPriority(rawValue: prioTitle)
                byUUID[uuid] = TaskMeta(title: title, updatedAt: updated, priority: prio)
            }
        }

        // Status for each prioritized block (may be absent for non-task blocks).
        let statusRows = try await query("""
            [:find ?uuid ?status-title
             :where [?b :logseq.property/priority ?p] [?p :block/title ?pt]
                    [(contains? #{"Urgent" "High" "Medium"} ?pt)]
                    [?b :block/uuid ?uuid]
                    [?b :logseq.property/status ?s] [?s :block/title ?status-title]]
            """)
        if let rows = statusRows as? [[Any]] {
            for row in rows {
                guard let uuid = row[0] as? String, let statusTitle = row[1] as? String,
                      byUUID[uuid] != nil else { continue }
                byUUID[uuid]!.status = statusTitle
            }
        }

        // Deadlines
        let deadlineRows = try await query("""
            [:find ?uuid ?deadline
             :where [?b :logseq.property/priority ?p] [?p :block/title ?pt]
                    [(contains? #{"Urgent" "High" "Medium"} ?pt)]
                    [?b :block/uuid ?uuid] [?b :logseq.property/deadline ?deadline]]
            """)
        if let rows = deadlineRows as? [[Any]] {
            for row in rows {
                guard let uuid = row[0] as? String, let d = row[1] as? Int,
                      byUUID[uuid] != nil else { continue }
                byUUID[uuid]!.deadline = d
            }
        }

        // Scheduled
        let scheduledRows = try await query("""
            [:find ?uuid ?scheduled
             :where [?b :logseq.property/priority ?p] [?p :block/title ?pt]
                    [(contains? #{"Urgent" "High" "Medium"} ?pt)]
                    [?b :block/uuid ?uuid] [?b :logseq.property/scheduled ?scheduled]]
            """)
        if let rows = scheduledRows as? [[Any]] {
            for row in rows {
                guard let uuid = row[0] as? String, let s = row[1] as? Int,
                      byUUID[uuid] != nil else { continue }
                byUUID[uuid]!.scheduled = s
            }
        }

        // Recurrence flag
        let recurRows = try await query("""
            [:find ?uuid
             :where [?b :logseq.property/priority ?p] [?p :block/title ?pt]
                    [(contains? #{"Urgent" "High" "Medium"} ?pt)]
                    [?b :block/uuid ?uuid] [?b :logseq.property.repeat/repeated? true]]
            """)
        var recurringUUIDs = Set<String>()
        if let rows = recurRows as? [[Any]] {
            for row in rows {
                if let uuid = row[0] as? String { recurringUUIDs.insert(uuid) }
            }
        }

        return byUUID.map { uuid, meta in
            LogseqBlock(uuid: uuid, title: meta.title, updatedAt: meta.updatedAt,
                        status: meta.status,   // nil if no status property (engine handles)
                        deadline: meta.deadline, scheduled: meta.scheduled,
                        isRecurring: recurringUUIDs.contains(uuid),
                        priority: meta.priority)
        }
    }

    func fetchBlock(uuid: String) async throws -> LogseqBlock? {
        let existResult = try await query("""
            [:find ?uuid ?updated ?title
             :where [?b :block/uuid #uuid "\(uuid)"] [?b :block/updated-at ?updated]
                    [?b :block/uuid ?uuid] [?b :block/title ?title]]
            """)
        guard let rows = existResult as? [[Any]], let row = rows.first,
              let retUUID = row[0] as? String,
              let updatedAt = jsonInt64(row[1]),
              let title = row[2] as? String else { return nil }

        let statusResult = try await query("""
            [:find ?status
             :where [?b :block/uuid #uuid "\(uuid)"]
                    [?b :logseq.property/status ?s] [?s :block/title ?status]]
            """)
        let status: String?
        if let sRows = statusResult as? [[Any]], let sRow = sRows.first,
           let s = sRow[0] as? String { status = s } else { status = nil }

        let deadlineResult = try await query("""
            [:find ?deadline
             :where [?b :block/uuid #uuid "\(uuid)"] [?b :logseq.property/deadline ?deadline]]
            """)
        let deadline: Int?
        if let dRows = deadlineResult as? [[Any]], let dRow = dRows.first,
           let d = dRow[0] as? Int { deadline = d } else { deadline = nil }

        let scheduledResult = try await query("""
            [:find ?scheduled
             :where [?b :block/uuid #uuid "\(uuid)"] [?b :logseq.property/scheduled ?scheduled]]
            """)
        let scheduled: Int?
        if let sRows = scheduledResult as? [[Any]], let sRow = sRows.first,
           let s = sRow[0] as? Int { scheduled = s } else { scheduled = nil }

        let recurResult = try await query("""
            [:find ?recur
             :where [?b :block/uuid #uuid "\(uuid)"]
                    [?b :logseq.property.repeat/repeated? ?recur]]
            """)
        let isRecurring: Bool
        if let rRows = recurResult as? [[Any]], let rRow = rRows.first,
           let r = rRow[0] as? Bool { isRecurring = r } else { isRecurring = false }

        let priorityResult = try await query("""
            [:find ?prio-title
             :where [?b :block/uuid #uuid "\(uuid)"]
                    [?b :logseq.property/priority ?p]
                    [?p :block/title ?prio-title]]
            """)
        let priority: LogseqPriority?
        if let pRows = priorityResult as? [[Any]], let pRow = pRows.first,
           let pTitle = pRow[0] as? String {
            if let parsed = LogseqPriority(rawValue: pTitle) {
                priority = parsed
            } else {
                logger?.log("WARN: unknown Logseq priority '\(pTitle)' on block \(uuid.prefix(8))…")
                priority = nil
            }
        } else {
            priority = nil
        }

        return LogseqBlock(uuid: retUUID, title: title, updatedAt: updatedAt,
                           status: status, deadline: deadline, scheduled: scheduled,
                           isRecurring: isRecurring, priority: priority)
    }

    // MARK: - Page title resolution (for [[uuid]] page-refs)

    /// Bulk-resolve `:block/title` for each block/page UUID. Returns a map of
    /// uuid → title. Missing UUIDs (no matching block) are simply absent.
    /// Issues one query per UUID — simple and fast at our scale; can be
    /// batched later if it becomes a bottleneck.
    func resolvePageTitles(uuids: [String]) async throws -> [String: String] {
        guard !uuids.isEmpty else { return [:] }
        var result: [String: String] = [:]
        for uuid in Set(uuids) {
            let rows = try await query("""
                [:find ?title
                 :where [?p :block/uuid #uuid "\(uuid)"] [?p :block/title ?title]]
                """)
            if let arr = rows as? [[Any]], let row = arr.first, let title = row.first as? String {
                result[uuid] = title
            }
        }
        return result
    }

    // MARK: - Child blocks (for notes)

    func fetchChildTitles(blockUUID: String) async throws -> [String] {
        // Exclude property-value entities via not-join on :logseq.property/created-from-property
        // (Property values are full blocks with parent/order/title set, so they'd otherwise
        // leak in as fake children — e.g. the reminder-id extId would appear as a "child.")
        let result = try await query("""
            [:find ?child-title ?order
             :where [?b :block/uuid #uuid "\(blockUUID)"]
                    [?child :block/parent ?b]
                    [?child :block/title ?child-title]
                    [?child :block/order ?order]
                    (not-join [?child]
                      [?child :logseq.property/created-from-property _])]
            """)
        guard let rows = result as? [[Any]] else { return [] }
        return rows
            .compactMap { row -> (title: String, order: String)? in
                guard let t = row[0] as? String, let o = row[1] as? String else { return nil }
                return (t, o)
            }
            .sorted { $0.order < $1.order }
            .map { $0.title }
    }

    // MARK: - Rebuild reads

    func fetchAllBlocksWithReminderIds() async throws -> [(uuid: String, extId: String)] {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let result = try await query("""
            [:find ?uuid ?str-val
             :where [?b :\(idents.reminderId) ?val]
                    [?b :block/uuid ?uuid] [?val :block/title ?str-val]]
            """)
        guard let rows = result as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard let u = row[0] as? String, let e = row[1] as? String else { return nil }
            return (u, e)
        }
    }

    func fetchAllBlocksWithCapturedIds() async throws -> [(uuid: String, extId: String)] {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let result = try await query("""
            [:find ?uuid ?str-val
             :where [?b :\(idents.capturedReminderId) ?val]
                    [?b :block/uuid ?uuid] [?val :block/title ?str-val]]
            """)
        guard let rows = result as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard let u = row[0] as? String, let e = row[1] as? String else { return nil }
            return (u, e)
        }
    }

    // MARK: - Writes

    func setReminderIdProperty(blockUUID: String, extId: String) async throws {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        _ = try await run([
            "upsert", "block", "-g", graph, "--uuid", blockUUID,
            "--update-properties=" + "{:\(idents.reminderId) \"\(Mapper.ednString(extId))\"}",
            "--output", "json"
        ])
    }

    func setBlockDate(blockUUID: String, field: LogseqDateField, epochMs: Int64) async throws {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let ident = field == .deadline ? idents.deadline : idents.scheduled
        _ = try await run([
            "upsert", "block", "-g", graph, "--uuid", blockUUID,
            "--update-properties=" + "{:\(ident) \(epochMs)}",
            "--output", "json"
        ])
    }

    /// Strip `reminder-id` and `captured-reminder-id` from every block in THIS client's
    /// graph. The caller pins the client to the OLD graph (idents resolved against it via
    /// `bootstrap()`), so this is `switch-graph`'s old-graph hygiene. Uses the proven
    /// `--remove-properties` mechanism (same as `clearBlockDate`), never an unproven
    /// `remove property` verb. Returns the number of property removals performed.
    @discardableResult
    func clearSyncProperties() async throws -> Int {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let mirror = try await fetchAllBlocksWithReminderIds()
        let captured = try await fetchAllBlocksWithCapturedIds()
        var cleared = 0
        // Best-effort per block: this is cosmetic old-graph hygiene (it doesn't affect
        // new-graph convergence), so a single stale/deleted UUID must not abort the whole
        // strip — and force a needless full switch-graph re-run.
        for (uuid, _) in mirror {
            do {
                _ = try await run([
                    "upsert", "block", "-g", graph, "--uuid", uuid,
                    "--remove-properties", "[:\(idents.reminderId)]",
                    "--output", "json"
                ])
                cleared += 1
            } catch {
                logger?.log("WARN: could not strip reminder-id from \(uuid.prefix(8))…: \(error.localizedDescription)")
            }
        }
        for (uuid, _) in captured {
            do {
                _ = try await run([
                    "upsert", "block", "-g", graph, "--uuid", uuid,
                    "--remove-properties", "[:\(idents.capturedReminderId)]",
                    "--output", "json"
                ])
                cleared += 1
            } catch {
                logger?.log("WARN: could not strip captured-reminder-id from \(uuid.prefix(8))…: \(error.localizedDescription)")
            }
        }
        return cleared
    }

    func clearBlockDate(blockUUID: String, field: LogseqDateField) async throws {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let ident = field == .deadline ? idents.deadline : idents.scheduled
        _ = try await run([
            "upsert", "block", "-g", graph, "--uuid", blockUUID,
            "--remove-properties", "[:\(ident)]",
            "--output", "json"
        ])
    }

    func updateTaskStatus(blockUUID: String, status: String) async throws {
        _ = try await run([
            "upsert", "task", "-g", graph,
            "--uuid", blockUUID, "--status", status, "--output", "json"
        ])
    }

    func setBlockPriority(blockUUID: String, priority: LogseqPriority) async throws {
        _ = try await run([
            "upsert", "task", "-g", graph,
            "--uuid", blockUUID, "--priority", priority.rawValue, "--output", "json"
        ])
    }

    func clearBlockPriority(blockUUID: String) async throws {
        _ = try await run([
            "upsert", "task", "-g", graph,
            "--uuid", blockUUID, "--no-priority", "--output", "json"
        ])
    }

    // MARK: - Journal / capture ingest

    /// Resolve where a journal capture should land *today*, given the inbox config.
    /// With `journalInboxTitle` set, the target is a (find-or-created) named sub-block;
    /// otherwise it's the journal page top level. Shared by the adopt (Step 7) and
    /// note-import (Step 7.5) paths so the placement rule lives in exactly one place.
    func todaysCaptureTarget(inboxTitle: String?) async throws -> CaptureTarget {
        let journalPage = try await resolveJournalPageTitle()
        guard let inboxTitle else { return .journalPage(name: journalPage) }
        let inboxUUID = try await findOrCreateInboxBlock(
            journalPage: journalPage, inboxTitle: inboxTitle)
        return .inboxBlock(uuid: inboxUUID)
    }

    /// Resolve the journal page title for today by looking it up in the graph by
    /// `:block/journal-day` — format-agnostic and works for any user's date format.
    /// If no journal exists for that day, attempts to create one; falls back to
    /// throwing `LogseqError.journalNotFound` so the capture is skipped per-item.
    func resolveJournalPageTitle(for date: Date = Date()) async throws -> String {
        // Local calendar throughout — matching how Logseq keys journal-day by civil date.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        cal.locale = Locale(identifier: "en_US_POSIX")

        let day = journalDay(for: date, calendar: cal)

        // Query returns [[title, uuid]] for all journals matching that day.
        let result = try await query("""
            [:find ?title ?uuid
             :where [?p :block/journal-day \(day)]
                    [?p :block/title ?title]
                    [?p :block/uuid ?uuid]]
            """)

        guard let rows = result as? [[Any]] else {
            throw LogseqError.unexpectedShape(
                "journal-day \(day) query: \(String(describing: result).prefix(200))")
        }

        switch rows.count {
        case 0:
            // No journal for this day — attempt to create one.
            return try await createJournalIfPossible(for: date, day: day, calendar: cal)

        case 1:
            guard let title = rows[0][0] as? String else {
                throw LogseqError.unexpectedShape("journal-day \(day) row: \(rows[0])")
            }
            return title

        default:
            // Multiple journals for this day — unexpected graph state.
            // Prefer the canonical UUID; never create a third journal.
            let n = rows.count
            let canonical = canonicalJournalUUID(for: date, calendar: cal)
            let preferred = rows.first(where: { ($0[1] as? String) == canonical }) ?? rows[0]
            let title = (preferred[0] as? String) ?? (rows[0][0] as? String) ?? ""
            logger?.log("WARN: \(n) journals found for \(day) — using '\(title)', not creating")
            return title
        }
    }

    /// Deterministic Logseq journal UUID: 00000001-YYYY-MMDD-0000-000000000000.
    private func canonicalJournalUUID(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "00000001-%04d-%02d%02d-0000-000000000000",
                      comps.year!, comps.month!, comps.day!)
    }

    /// Attempt to create a journal for `date`. Validates the renderer against
    /// existing journals before creating. Throws `journalNotFound` on any failure
    /// so the per-item catch in SyncEngine skips just this capture.
    private func createJournalIfPossible(for date: Date, day: Int, calendar: Calendar) async throws -> String {
        let format = await fetchJournalTitleFormat()

        guard await validateRenderer(format: format, calendar: calendar) else {
            let fallback = fallbackDateLabel(for: date, calendar: calendar)
            throw LogseqError.journalNotFound(
                "Today's journal (\(fallback)) doesn't exist yet and the renderer " +
                "couldn't be validated — open Logseq once to create it.")
        }

        guard let title = renderJournalTitle(date: date, format: format, calendar: calendar) else {
            throw LogseqError.journalNotFound(
                "Today's journal date format '\(format)' is not fully supported. " +
                "Open Logseq to create the journal page.")
        }

        // PoC required before shipping create: confirm which CLI command produces a
        // proper journal (journal-day + Journal tag). Implemented below after PoC.
        logger?.log("INFO: journal '\(title)' (\(day)) is missing — auto-create not yet implemented. Open Logseq to create it.")
        throw LogseqError.journalNotFound(
            "Today's journal page '\(title)' does not exist yet — open Logseq " +
            "once and it will sync on the next run.")
    }

    /// Fetch the graph's journal title format setting.
    /// Falls back to "MMM do, yyyy" (the Logseq DB default) if the property is absent.
    private func fetchJournalTitleFormat() async -> String {
        guard let result = try? await query(
            "[:find ?fmt :where [?e :logseq.property.journal/title-format ?fmt]]"
        ), let rows = result as? [[Any]],
           let fmt = rows.first?[0] as? String, !fmt.isEmpty else {
            return "MMM do, yyyy"
        }
        return fmt
    }

    /// Self-validate the renderer: render the most recent journal's date and compare
    /// to its stored title. Returns false if mismatch, or if no journals exist.
    private func validateRenderer(format: String, calendar: Calendar) async -> Bool {
        guard let maxResult = try? await query(
            "[:find (max ?d) :where [?p :block/journal-day ?d]]"
        ), let maxRows = maxResult as? [[Any]],
           let maxRow = maxRows.first,
           let rawDay = maxRow.first,
           let maxDay = jsonInt64(rawDay).map({ Int($0) }) else {
            logger?.log("Journal renderer: no existing journals — cannot validate, skipping create")
            return false
        }

        guard let titleResult = try? await query(
            "[:find ?title :where [?p :block/journal-day \(maxDay)] [?p :block/title ?title]]"
        ), let titleRows = titleResult as? [[Any]],
           let storedTitle = titleRows.first?[0] as? String else {
            logger?.log("Journal renderer: cannot fetch title for \(maxDay) — skipping create")
            return false
        }

        var comps = DateComponents()
        comps.year = maxDay / 10000
        comps.month = (maxDay % 10000) / 100
        comps.day = maxDay % 100
        guard let maxDate = calendar.date(from: comps) else {
            logger?.log("Journal renderer: cannot reconstruct date for \(maxDay) — skipping create")
            return false
        }

        guard let rendered = renderJournalTitle(date: maxDate, format: format, calendar: calendar) else {
            logger?.log("Journal renderer: unsupported format '\(format)' — skipping create")
            return false
        }

        if rendered != storedTitle {
            logger?.log(
                "Journal renderer: mismatch for \(maxDay) — rendered '\(rendered)' " +
                "vs stored '\(storedTitle)' — skipping create")
            return false
        }

        return true
    }

    private func fallbackDateLabel(for date: Date, calendar: Calendar) -> String {
        // "MMM d, yyyy" contains no unsupported tokens so renderJournalTitle never returns nil here.
        return renderJournalTitle(date: date, format: "MMM d, yyyy", calendar: calendar) ?? "(unknown date)"
    }

    /// Find existing Inbox block or create it on the journal page. Returns the block UUID.
    func findOrCreateInboxBlock(journalPage: String, inboxTitle: String) async throws -> String {
        let safeTitle = Mapper.ednString(inboxTitle)
        let existResult = try await query("""
            [:find ?uuid
             :where [?p :block/title "\(journalPage)"] [?p :block/journal-day _]
                    [?child :block/parent ?p] [?child :block/title "\(safeTitle)"]
                    [?child :block/uuid ?uuid]]
            """)
        if let rows = existResult as? [[Any]], let row = rows.first,
           let uuid = row[0] as? String { return uuid }

        // Create the inbox block
        let createResult = try await run([
            "upsert", "block", "-g", graph,
            "--target-page", journalPage,
            "--content=" + inboxTitle,
            "--output", "json"
        ])
        return try await extractCreatedUUID(from: createResult, context: "inbox block")
    }

    /// Create a mirror-capture task at the given target on the journal page.
    ///
    /// Writes `reminder-id` (NOT `captured-reminder-id`) atomically in the same upsert
    /// that creates the block, so a crash between this and the promote cannot leave
    /// an orphaned block with no anchor. The `.linkedRebuild` path recovers a crashed
    /// half-create via `reminder-id`; without the atomic anchor it would see a
    /// priority-less block and the F.2.3 teardown would delete the user's reminder.
    ///
    /// The promote (`upsert task`) is NOT silenced with `try?` — it must succeed so the
    /// block has a status and priority, preventing a spurious priority-loss teardown.
    ///
    /// Returns the new block UUID.
    func createCaptureTask(
        target: CaptureTarget,
        title: String,
        reminderExtId: String,
        status: String,
        priority: LogseqPriority? = nil,
        paragraphs: [String] = []
    ) async throws -> String {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let targetArgs = target.cliArgs
        // Atomic: block content + reminder-id in one upsert.
        let createResult = try await run(
            ["upsert", "block", "-g", graph] + targetArgs + [
            "--content=" + title,
            "--update-properties=" + "{:\(idents.reminderId) \"\(Mapper.ednString(reminderExtId))\"}",
            "--output", "json"
        ])
        let blockUUID = try await extractCreatedUUID(from: createResult, context: "capture task")
        // Promote to a #Task node with the matching status. NOT try? — must succeed.
        var promoteArgs = [
            "upsert", "task", "-g", graph,
            "--uuid", blockUUID,
            "--status", status
        ]
        if let priority {
            promoteArgs.append(contentsOf: ["--priority", priority.rawValue])
        }
        promoteArgs.append(contentsOf: ["--output", "json"])
        _ = try await run(promoteArgs)
        // Append body paragraphs as nested children, in order. Paragraphs appended after
        // promote so a child is never accidentally promoted. On any failure roll the whole
        // block back so the next pass re-adopts cleanly (mirrors createNote).
        if !paragraphs.isEmpty {
            do {
                for paragraph in paragraphs {
                    _ = try await run([
                        "upsert", "block", "-g", graph,
                        "--target-uuid", blockUUID,
                        "--content=" + paragraph,
                        "--output", "json"
                    ])
                }
            } catch {
                _ = try? await run([
                    "remove", "block", "-g", graph,
                    "--uuid", blockUUID,
                    "--output", "json"
                ])
                throw error
            }
        }
        return blockUUID
    }

    /// Create a one-way NOTE capture at the given target on the journal page.
    ///
    /// Writes `captured-reminder-id` (NOT `reminder-id`) atomically in the same upsert
    /// that creates the title block — anchor-first, so a crash mid-import leaves an
    /// anchored note (re-classified `.alreadyIngested`, skipped) rather than a duplicate
    /// top block. The note is deliberately NOT promoted to a `#Task`: it carries no status.
    ///
    /// Each paragraph becomes a nested child block under the title, appended in order.
    /// Returns the new top-block UUID.
    func createNote(
        target: CaptureTarget,
        title: String,
        paragraphs: [String],
        capturedReminderExtId: String
    ) async throws -> String {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let targetArgs = target.cliArgs
        // Atomic: title block content + captured-reminder-id anchor in one upsert.
        let createResult = try await run(
            ["upsert", "block", "-g", graph] + targetArgs + [
            "--content=" + title,
            "--update-properties=" + "{:\(idents.capturedReminderId) \"\(Mapper.ednString(capturedReminderExtId))\"}",
            "--output", "json"
        ])
        let topUUID = try await extractCreatedUUID(from: createResult, context: "note title")
        // Append each paragraph as a nested child block, in order. On any failure, roll
        // back the anchored title block so the next pass gets a clean retry (freshNote).
        do {
            for paragraph in paragraphs {
                _ = try await run([
                    "upsert", "block", "-g", graph,
                    "--target-uuid", topUUID,
                    "--content=" + paragraph,
                    "--output", "json"
                ])
            }
        } catch {
            _ = try? await run([
                "remove", "block", "-g", graph,
                "--uuid", topUUID,
                "--output", "json"
            ])
            throw error
        }
        return topUUID
    }

    // MARK: - Shell execution

    func run(_ args: [String]) async throws -> Any {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

                guard p.terminationStatus == 0 else {
                    let errStr = String(data: errData, encoding: .utf8) ?? "(no stderr)"
                    let outStr = String(data: outData, encoding: .utf8) ?? ""
                    continuation.resume(throwing: LogseqError.cliFailed(
                        args: args.prefix(6).joined(separator: " "),
                        status: p.terminationStatus,
                        output: "\(outStr)\n\(errStr)".trimmingCharacters(in: .whitespacesAndNewlines)
                    ))
                    return
                }

                do {
                    let envelope = try JSONSerialization.jsonObject(with: outData)
                    continuation.resume(returning: envelope)
                } catch {
                    continuation.resume(throwing: LogseqError.jsonParse(
                        String(data: outData, encoding: .utf8) ?? ""))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Graph-wide max datascript transaction id — a single integer the database
    /// bumps on every datom write (any block/property/tag/page change). Used as the
    /// Logseq-side change-signal for the smart-polling gate. Needs no `bootstrap()`:
    /// the query binds only the built-in tx slot. Throws on an empty/non-numeric
    /// result so the gate falls through to a full run (over-trigger, never under).
    func fetchMaxTx() async throws -> Int64 {
        let result = try await query("[:find (max ?tx) :where [?e ?a ?v ?tx]]")
        guard let rows = result as? [[Any]], let row = rows.first, !row.isEmpty,
              let tx = jsonInt64(row[0]) else {
            throw LogseqError.unexpectedShape("max-tx query: \(String(describing: result).prefix(200))")
        }
        return tx
    }

    // MARK: - Helpers

    private func query(_ edn: String) async throws -> Any {
        let result = try await run(["query", "-g", graph, "--query", edn, "--output", "json"])
        guard let dict = result as? [String: Any],
              let data = dict["data"] as? [String: Any],
              let rows = data["result"] else {
            throw LogseqError.unexpectedShape(String(describing: result).prefix(200).description)
        }
        return rows
    }

    private func parseItems(_ envelope: Any) throws -> [[String: Any]] {
        guard let dict = envelope as? [String: Any],
              let data = dict["data"] as? [String: Any],
              let items = data["items"] as? [[String: Any]] else {
            throw LogseqError.unexpectedShape(String(describing: envelope))
        }
        return items
    }

    private func extractCreatedUUID(from result: Any, context: String) async throws -> String {
        // upsert block create returns db/id; we need to query for UUID.
        guard let dict = result as? [String: Any],
              let data = dict["data"] as? [String: Any] else {
            throw LogseqError.unexpectedShape("create \(context): \(result)")
        }
        // If result is a UUID string array
        if let uuids = data["result"] as? [String], let uuid = uuids.first { return uuid }
        // If result is a db/id array — query for UUID
        if let dbIds = data["result"] as? [Int], let dbId = dbIds.first {
            return try await fetchUUIDForDBId(dbId)
        }
        throw LogseqError.unexpectedShape("create \(context) result: \(data)")
    }

    private func fetchUUIDForDBId(_ dbId: Int) async throws -> String {
        let result = try await query(
            "[:find ?uuid :where [\(dbId) :block/uuid ?uuid]]"
        )
        guard let rows = result as? [[Any]], let row = rows.first,
              let uuid = row[0] as? String else {
            throw LogseqError.unexpectedShape("uuid lookup for db/id \(dbId)")
        }
        return uuid
    }

    private func extractStatusTitle(_ ident: String) -> String? {
        guard let last = ident.split(separator: ".").last else { return nil }
        switch String(last) {
        case "doing": return "Doing"
        case "todo": return "Todo"
        case "done": return "Done"
        case "backlog": return "Backlog"
        case "in-review": return "In Review"
        case "canceled", "cancelled": return "Canceled"
        default: return nil
        }
    }

    private func jsonInt64(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? Double { return Int64(v) }
        return nil
    }
}

// MARK: - Errors

enum LogseqError: Error, LocalizedError {
    case propertyNotFound(String)
    case notBootstrapped
    case cliFailed(args: String, status: Int32, output: String)
    case jsonParse(String)
    case unexpectedShape(String)
    case journalNotFound(String)

    var errorDescription: String? {
        switch self {
        case .propertyNotFound(let name): return "Logseq property not found: \(name)"
        case .notBootstrapped: return "LogseqClient not bootstrapped"
        case .cliFailed(let args, let status, let output):
            return "logseq CLI failed (exit \(status)) for '\(args)': \(output)"
        case .jsonParse(let raw): return "JSON parse error: \(raw.prefix(200))"
        case .unexpectedShape(let raw): return "Unexpected CLI response shape: \(raw.prefix(200))"
        case .journalNotFound(let msg): return msg
        }
    }
}
