import Foundation
import SyncCore

struct PropertyIdents {
    let reminderId: String
    let capturedReminderId: String
    let deadline: String
    let scheduled: String
    let repeated: String
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
            "--update-properties", "{:\(idents.reminderId) \"\(extId)\"}",
            "--output", "json"
        ])
    }

    func setBlockDate(blockUUID: String, field: LogseqDateField, epochMs: Int64) async throws {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        let ident = field == .deadline ? idents.deadline : idents.scheduled
        _ = try await run([
            "upsert", "block", "-g", graph, "--uuid", blockUUID,
            "--update-properties", "{:\(ident) \(epochMs)}",
            "--output", "json"
        ])
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

    static func journalPageName(for date: Date = Date()) -> String {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let day = comps.day!
        let month = ["January","February","March","April","May","June",
                     "July","August","September","October","November","December"][comps.month! - 1]
        let suffix: String
        switch day {
        case 1, 21, 31: suffix = "st"
        case 2, 22: suffix = "nd"
        case 3, 23: suffix = "rd"
        default: suffix = "th"
        }
        return "\(month) \(day)\(suffix), \(comps.year!)"
    }

    /// Find existing Inbox block or create it on the journal page. Returns the block UUID.
    func findOrCreateInboxBlock(journalPage: String, inboxTitle: String) async throws -> String {
        let existResult = try await query("""
            [:find ?uuid
             :where [?p :block/title "\(journalPage)"] [?p :block/journal-day _]
                    [?child :block/parent ?p] [?child :block/title "\(inboxTitle)"]
                    [?child :block/uuid ?uuid]]
            """)
        if let rows = existResult as? [[Any]], let row = rows.first,
           let uuid = row[0] as? String { return uuid }

        // Create the inbox block
        let createResult = try await run([
            "upsert", "block", "-g", graph,
            "--target-page", journalPage,
            "--content", inboxTitle,
            "--output", "json"
        ])
        return try await extractCreatedUUID(from: createResult, context: "inbox block")
    }

    /// Create a mirror-capture task under the inbox block.
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
        inboxBlockUUID: String,
        title: String,
        reminderExtId: String,
        status: String,
        priority: LogseqPriority? = nil
    ) async throws -> String {
        guard let idents = propertyIdents else { throw LogseqError.notBootstrapped }
        // Atomic: block content + reminder-id in one upsert.
        let createResult = try await run([
            "upsert", "block", "-g", graph,
            "--target-uuid", inboxBlockUUID,
            "--content", title,
            "--update-properties", "{:\(idents.reminderId) \"\(reminderExtId)\"}",
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
        return blockUUID
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

    var errorDescription: String? {
        switch self {
        case .propertyNotFound(let name): return "Logseq property not found: \(name)"
        case .notBootstrapped: return "LogseqClient not bootstrapped"
        case .cliFailed(let args, let status, let output):
            return "logseq CLI failed (exit \(status)) for '\(args)': \(output)"
        case .jsonParse(let raw): return "JSON parse error: \(raw.prefix(200))"
        case .unexpectedShape(let raw): return "Unexpected CLI response shape: \(raw.prefix(200))"
        }
    }
}
