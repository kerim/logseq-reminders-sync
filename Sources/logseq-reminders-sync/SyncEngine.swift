import Foundation
import SyncCore

struct SyncEngine {
    var logseq: LogseqClient
    let reminders: RemindersStore
    let stateStore: StateStore
    let config: Config
    let logger: RunLogger
    private var state: SyncState

    init(logseq: LogseqClient, reminders: RemindersStore,
         stateStore: StateStore, config: Config, logger: RunLogger) {
        self.logseq = logseq
        self.reminders = reminders
        self.stateStore = stateStore
        self.config = config
        self.logger = logger
        self.state = stateStore.load()
    }

    mutating func run() async throws {
        logger.log("Sync started — graph: \(config.graph), list: \(config.remindersListTitle)")

        // ── Step 3(a): Read Doing tasks and paired recurring non-Doing blocks ──
        let doingTasks = try await logseq.fetchDoingTasks()
        var doingByUUID: [String: LogseqBlock] = [:]
        for t in doingTasks { doingByUUID[t.uuid] = t }

        logger.log("Doing tasks: \(doingTasks.count)")

        // Pre-fetch property maps for confirm-guard + reindex
        let allWithRemIds = try await logseq.fetchAllBlocksWithReminderIds()
        var blockUUIDForExtId: [String: String] = [:]
        var extIdCounts: [String: Int] = [:]
        for (uuid, extId) in allWithRemIds {
            extIdCounts[extId, default: 0] += 1
            blockUUIDForExtId[extId] = uuid
        }
        for (extId, count) in extIdCounts where count > 1 {
            logger.log("WARN: Duplicate reminder-id for extId \(extId.prefix(8))… — skipping for re-pair")
            blockUUIDForExtId.removeValue(forKey: extId)
        }

        let allWithCapIds = try await logseq.fetchAllBlocksWithCapturedIds()
        var captureUUIDForExtId: [String: String] = [:]
        for (uuid, extId) in allWithCapIds { captureUUIDForExtId[extId] = uuid }

        // ── Step 3(b): Fetch out-of-filter linked blocks ─────────────────────
        var linkedStatus: [String: LogseqBlock?] = [:]
        for pair in state.pairs where doingByUUID[pair.logseqUUID] == nil {
            linkedStatus[pair.logseqUUID] = try await logseq.fetchBlock(uuid: pair.logseqUUID)
        }

        // ── Step 3(c): Reindex guard ──────────────────────────────────────────
        for i in state.pairs.indices {
            let pair = state.pairs[i]
            guard doingByUUID[pair.logseqUUID] == nil else { continue }
            guard let found = linkedStatus[pair.logseqUUID], found == nil else { continue }
            // Block not found by UUID — check if UUID changed (reindex)
            if let newUUID = blockUUIDForExtId[pair.reminderExtId], newUUID != pair.logseqUUID {
                logger.log("Reindex: \(pair.logseqUUID.prefix(8))… → \(newUUID.prefix(8))…")
                linkedStatus[newUUID] = try await logseq.fetchBlock(uuid: newUUID)
                linkedStatus.removeValue(forKey: pair.logseqUUID)
                state.pairs[i].logseqUUID = newUUID
            }
        }

        // ── Step 4: Classify Reminders ────────────────────────────────────────
        let lookback: Date = {
            if let last = state.lastRunDate {
                return Calendar.current.date(byAdding: .day, value: -1, to: last)!
            }
            return Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        }()

        let incompleteSnaps = try await reminders.fetchIncomplete()
        let completedSnaps = try await reminders.fetchCompleted(since: lookback)
        let allSnaps = incompleteSnaps + completedSnaps
        logger.log("Reminders: \(incompleteSnaps.count) incomplete, \(completedSnaps.count) recently completed")

        enum Cls {
            case linked(idx: Int)
            case linkedRebuild(blockUUID: String)
            case alreadyIngested(journalUUID: String)
            case fresh
        }

        var pairIndexByLocalId: [String: Int] = [:]
        for (i, p) in state.pairs.enumerated() { pairIndexByLocalId[p.reminderLocalId] = i }

        let archivedExtIdSet = Set(state.archivedExtIds)
        var skippedArchivedCount = 0
        var classified: [(ReminderSnapshot, Cls)] = []
        for snap in allSnaps {
            // 1. In state by localId
            if let idx = pairIndexByLocalId[snap.localId] {
                classified.append((snap, .linked(idx: idx))); continue
            }
            // 2. In state by extId
            let extMatches = state.pairs.enumerated().filter { $0.element.reminderExtId == snap.extId }
            if extMatches.count == 1 {
                classified.append((snap, .linked(idx: extMatches[0].offset))); continue
            } else if extMatches.count > 1 {
                logger.log("WARN: Ambiguous extId \(snap.extId.prefix(8))…")
            }
            // 3. Archived (completed recurring cycle) — skip entirely
            if archivedExtIdSet.contains(snap.extId) {
                skippedArchivedCount += 1
                continue
            }
            // 4. Logseq reminder-id property index → linked mirror (rebuild)
            if let blockUUID = blockUUIDForExtId[snap.extId] {
                classified.append((snap, .linkedRebuild(blockUUID: blockUUID))); continue
            }
            // 5. Logseq captured-reminder-id property index → already ingested
            if let journalUUID = captureUUIDForExtId[snap.extId] {
                classified.append((snap, .alreadyIngested(journalUUID: journalUUID))); continue
            }
            // 6. Anything else → fresh capture (user-typed reminder in the Logseq list)
            classified.append((snap, .fresh))
        }
        if skippedArchivedCount > 0 {
            logger.log("Skipped \(skippedArchivedCount) archived recurring-cycle reminder(s)")
        }

        let freshCount = classified.filter { if case .fresh = $0.1 { true } else { false } }.count
        let linkedCount = classified.filter { if case .linked = $0.1 { true } else { false } }.count
        let rebuildCount = classified.filter { if case .linkedRebuild = $0.1 { true } else { false } }.count
        let ingestedCount = classified.filter { if case .alreadyIngested = $0.1 { true } else { false } }.count
        logger.log("Classified: \(linkedCount) linked, \(rebuildCount) rebuild, \(ingestedCount) ingested, \(freshCount) fresh")

        // ── Step 4.5: Rebuild pairs from Logseq reminder-id property index ────
        var rebuiltLocalIds = Set<String>()
        for (snap, cls) in classified {
            guard case .linkedRebuild(let blockUUID) = cls else { continue }
            guard let block = try await logseq.fetchBlock(uuid: blockUUID) else {
                // Block disappeared between the property scan and now — orphan reminder.
                logger.log("Rebuild target \(blockUUID.prefix(8))… gone → deleting reminder")
                try await reminders.deleteReminder(localId: snap.localId)
                continue
            }
            logger.log("Rebuilding pair: \(blockUUID.prefix(8))… ↔ reminder \(snap.localId.prefix(8))…")
            let status = block.status ?? "Doing"
            let logseqDone = Mapper.logseqStatusIsCompleted(status)
            let childTitles = try await logseq.fetchChildTitles(blockUUID: blockUUID)
            let (titleStr, notesStr) = try await buildTitleAndNotes(
                blockTitle: block.title, childTitles: childTitles
            )
            let pair = SyncPair(
                logseqUUID: blockUUID,
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                lastStatus: status,
                lastOpenStatus: logseqDone ? "Doing" : status,
                lastCompleted: logseqDone,
                lastLogseqUpdated: block.updatedAt,
                lastReminderMod: snap.lastModified.map { ms($0) },
                lastTitle: titleStr,
                lastNotesHash: Mapper.hashNotes(notesStr)
            )
            state.pairs.append(pair)
            // Force-sync reminder to Logseq state (authoritative)
            if logseqDone && !snap.isCompleted {
                logger.log("  → completing reminder to match Logseq Done")
                try await reminders.completeReminder(localId: snap.localId)
            } else if !logseqDone && snap.isCompleted {
                logger.log("  → uncompleting reminder to match Logseq open state")
                try? await reminders.updateReminder(localId: snap.localId, isCompleted: false)
            }
            rebuiltLocalIds.insert(snap.localId)
        }
        // Rebuild index after appending
        pairIndexByLocalId = [:]
        for (i, p) in state.pairs.enumerated() { pairIndexByLocalId[p.reminderLocalId] = i }

        // ── Step 5: Reconcile linked pairs ────────────────────────────────────
        let linkedLocalIds: Set<String> = Set(
            classified.compactMap { snap, cls -> String? in
                if case .linked = cls { return snap.localId }
                return nil
            } + rebuiltLocalIds
        )

        var pairsToRemove = Set<String>()  // logseqUUIDs

        for i in state.pairs.indices {
            let pair = state.pairs[i]
            let uuid = pair.logseqUUID

            // Skip newly-rebuilt pairs (already force-synced above)
            if rebuiltLocalIds.contains(pair.reminderLocalId) { continue }

            // Block disposition
            let currentBlock: LogseqBlock?
            let isInFilter: Bool
            if let b = doingByUUID[uuid] {
                currentBlock = b; isInFilter = true
            } else if let found = linkedStatus[uuid], let b = found {
                currentBlock = b; isInFilter = false
            } else {
                currentBlock = nil; isInFilter = false
            }

            // Block genuinely deleted?
            if currentBlock == nil {
                logger.log("Block \(uuid.prefix(8))… deleted → deleting reminder")
                try await reminders.deleteReminder(localId: pair.reminderLocalId)
                pairsToRemove.insert(uuid); continue
            }

            let block = currentBlock!
            let currentStatus = block.status ?? "Doing"
            let logseqCompleted = Mapper.logseqStatusIsCompleted(currentStatus)

            // Hoist snapshot fetch so the left-filter branch can inspect live.isCompleted.
            // (We fetch even for out-of-filter blocks because the recurrence carve-out needs it.)
            guard let live = await reminders.fetchSnapshot(localId: pair.reminderLocalId) else {
                pairsToRemove.insert(uuid); continue
            }

            // Block left filter?
            if !isInFilter {
                if logseqCompleted {
                    logger.log("Block \(uuid.prefix(8))… → \(currentStatus), completing reminder")
                    if !pair.lastCompleted {
                        try await reminders.completeReminder(localId: pair.reminderLocalId)
                    }
                    pairsToRemove.insert(uuid); continue
                } else if block.isRecurring && (pair.lastCompleted || live.isCompleted) {
                    // Recurring task cycle completed: Logseq auto-advanced to an open
                    // status after the user marked the reminder Done. Drop the pair and
                    // archive the reminder's extId so future syncs don't re-capture it.
                    // The completed reminder stays in Apple Reminders' Completed section
                    // as history. To re-engage the task, the user moves it back to Doing.
                    if !state.archivedExtIds.contains(pair.reminderExtId) {
                        state.archivedExtIds.append(pair.reminderExtId)
                    }
                    logger.log("Recurring \(uuid.prefix(8))… cycle complete (\(currentStatus)) — pair dropped, reminder archived")
                    pairsToRemove.insert(uuid); continue
                } else {
                    logger.log("Block \(uuid.prefix(8))… left filter (\(currentStatus)) → deleting reminder")
                    try await reminders.deleteReminder(localId: pair.reminderLocalId)
                    pairsToRemove.insert(uuid); continue
                }
            }

            // Reminder gone?
            if !linkedLocalIds.contains(pair.reminderLocalId) {
                logger.log("Reminder for \(uuid.prefix(8))… gone → dropping link (will re-mirror)")
                pairsToRemove.insert(uuid); continue
            }

            // Confirm-on-write guard: ensure the localId hasn't been reused for a
            // different reminder. extId is regenerated on reminder re-creation, so
            // if the live reminder's extId still matches our pair, it IS our
            // reminder. As a fallback, check that the Logseq block still carries
            // the matching reminder-id property.
            let extIdMatch = live.extId == pair.reminderExtId
            let propMatch = blockUUIDForExtId[pair.reminderExtId] == uuid
            guard extIdMatch || propMatch else {
                logger.log("WARN: Confirm guard failed for \(uuid.prefix(8))… — skipping")
                continue
            }


            // ── 3-way merge ──────────────────────────────────────────────────
            let logseqChanged = currentStatus != pair.lastStatus
            let reminderCompleted = live.isCompleted
            let reminderChanged = reminderCompleted != pair.lastCompleted
            let logseqMs = block.updatedAt
            let reminderMs: Int64? = live.lastModified.map { ms($0) }

            var updated = pair

            if logseqCompleted == reminderCompleted {
                // Both sides agree — converged
                if logseqChanged || reminderChanged {
                    logger.log("Converged for \(uuid.prefix(8))… (\(currentStatus)/completed:\(reminderCompleted))")
                }
                updated.lastStatus = currentStatus
                if !logseqCompleted { updated.lastOpenStatus = currentStatus }
                updated.lastCompleted = reminderCompleted
                updated.lastReminderMod = reminderMs
                updated.lastLogseqUpdated = logseqMs
            } else if logseqChanged && !reminderChanged {
                // Logseq changed → push to Reminder
                logger.log("Logseq changed \(uuid.prefix(8))…: \(pair.lastStatus) → \(currentStatus)")
                if logseqCompleted {
                    try await reminders.completeReminder(localId: pair.reminderLocalId)
                } else {
                    try? await reminders.updateReminder(localId: pair.reminderLocalId, isCompleted: false)
                }
                if let fresh = await reminders.fetchSnapshot(localId: pair.reminderLocalId) {
                    updated.lastReminderMod = fresh.lastModified.map { ms($0) }
                    updated.lastCompleted = fresh.isCompleted
                }
                updated.lastStatus = currentStatus
                if !logseqCompleted { updated.lastOpenStatus = currentStatus }
                updated.lastLogseqUpdated = logseqMs
            } else if !logseqChanged && reminderChanged {
                // Reminder changed → push to Logseq
                logger.log("Reminder changed \(uuid.prefix(8))…: \(pair.lastCompleted) → \(reminderCompleted)")
                if reminderCompleted {
                    try await logseq.updateTaskStatus(blockUUID: uuid, status: "Done")
                } else {
                    let restore = Mapper.openStatusToRestore(lastOpenStatus: pair.lastOpenStatus)
                    try await logseq.updateTaskStatus(blockUUID: uuid, status: restore)
                }
                if let fresh = try await logseq.fetchBlock(uuid: uuid) {
                    updated.lastLogseqUpdated = fresh.updatedAt
                    let newStatus = fresh.status ?? currentStatus
                    updated.lastStatus = newStatus
                    if !Mapper.logseqStatusIsCompleted(newStatus) { updated.lastOpenStatus = newStatus }
                }
                updated.lastReminderMod = reminderMs
                updated.lastCompleted = reminderCompleted
            } else {
                // Both changed and disagree — conflict resolution
                let rMs = reminderMs ?? 0
                if logseqMs == rMs {
                    logger.log("CONFLICT TIE \(uuid.prefix(8))… — no write, state updated")
                    updated.lastStatus = currentStatus
                    if !logseqCompleted { updated.lastOpenStatus = currentStatus }
                    updated.lastCompleted = reminderCompleted
                    updated.lastReminderMod = reminderMs
                    updated.lastLogseqUpdated = logseqMs
                } else if logseqMs > rMs {
                    logger.log("CONFLICT \(uuid.prefix(8))…: Logseq wins (newer)")
                    if logseqCompleted {
                        try await reminders.completeReminder(localId: pair.reminderLocalId)
                    } else {
                        try? await reminders.updateReminder(localId: pair.reminderLocalId, isCompleted: false)
                    }
                    updated.lastStatus = currentStatus
                    if !logseqCompleted { updated.lastOpenStatus = currentStatus }
                    updated.lastLogseqUpdated = logseqMs
                    updated.lastCompleted = logseqCompleted
                } else {
                    logger.log("CONFLICT \(uuid.prefix(8))…: Reminder wins (newer)")
                    if reminderCompleted {
                        try await logseq.updateTaskStatus(blockUUID: uuid, status: "Done")
                    } else {
                        let restore = Mapper.openStatusToRestore(lastOpenStatus: pair.lastOpenStatus)
                        try await logseq.updateTaskStatus(blockUUID: uuid, status: restore)
                    }
                    updated.lastReminderMod = reminderMs
                    updated.lastCompleted = reminderCompleted
                }
            }

            // ── Text/notes sync (one-way Logseq → Reminders) ────────────────
            let childTitles = try await logseq.fetchChildTitles(blockUUID: uuid)
            let (newTitle, newNotes) = try await buildTitleAndNotes(
                blockTitle: block.title, childTitles: childTitles
            )
            let notesHash = Mapper.hashNotes(newNotes)
            if newTitle != updated.lastTitle || notesHash != updated.lastNotesHash {
                try? await reminders.updateReminder(
                    localId: pair.reminderLocalId,
                    title: newTitle,
                    notes: newNotes
                )
                if let fresh = await reminders.fetchSnapshot(localId: pair.reminderLocalId) {
                    updated.lastReminderMod = fresh.lastModified.map { ms($0) }
                }
                updated.lastTitle = newTitle
                updated.lastNotesHash = notesHash
            }

            // ── Date 3-way merge (independent of status merge) ───────────────
            if config.syncDates {
                updated = try await mergeDates(updated: updated, block: block, live: live)
            }

            state.pairs[i] = updated
        }

        state.pairs.removeAll { pairsToRemove.contains($0.logseqUUID) }

        // ── Step 6: Mirror new Doing tasks ────────────────────────────────────
        let pairedUUIDs = Set(state.pairs.map { $0.logseqUUID })
        for mirrorBlock in doingTasks where !pairedUUIDs.contains(mirrorBlock.uuid) {
            logger.log("Mirroring \(mirrorBlock.uuid.prefix(8))…: \(mirrorBlock.title.prefix(60))")
            let childTitles = try await logseq.fetchChildTitles(blockUUID: mirrorBlock.uuid)
            let (title, notes) = try await buildTitleAndNotes(
                blockTitle: mirrorBlock.title, childTitles: childTitles
            )
            let hash = Mapper.hashNotes(notes)
            let dueDateMs = (mirrorBlock.deadline ?? mirrorBlock.scheduled).map { Int64($0) }
            let dueSource = Mapper.preferredDateField(
                deadline: mirrorBlock.deadline, scheduled: mirrorBlock.scheduled)
            let dueComponents: DateComponents? = config.syncDates ? dueDateMs.map {
                Mapper.epochMsToDueComponents($0)
            } : nil
            let snap = try await reminders.createReminder(
                title: title, notes: notes, dueComponents: dueComponents)
            try await logseq.setReminderIdProperty(blockUUID: mirrorBlock.uuid, extId: snap.extId)
            let status = mirrorBlock.status ?? "Doing"
            let pair = SyncPair(
                logseqUUID: mirrorBlock.uuid,
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                lastStatus: status,
                lastOpenStatus: Mapper.logseqStatusIsCompleted(status) ? "Doing" : status,
                lastCompleted: snap.isCompleted,
                lastLogseqUpdated: mirrorBlock.updatedAt,
                lastReminderMod: snap.lastModified.map { ms($0) },
                lastTitle: title,
                lastNotesHash: hash,
                lastDueDateMs: config.syncDates ? dueDateMs : nil,
                lastDueSource: config.syncDates ? dueSource : nil
            )
            state.pairs.append(pair)
        }

        // ── Step 7: Ingest fresh captures ─────────────────────────────────────
        let knownCapExtIds = Set(state.captures.map { $0.reminderExtId })
        for (snap, cls) in classified {
            guard case .fresh = cls else { continue }
            // Skip if already recorded in state
            if knownCapExtIds.contains(snap.extId) { continue }
            // Skip if anchor block already created (partial ingest — just archive)
            if captureUUIDForExtId[snap.extId] != nil {
                logger.log("Resuming partial ingest: \(snap.title.prefix(60))")
                if !snap.isCompleted { try await reminders.completeReminder(localId: snap.localId) }
                continue
            }
            logger.log("Ingesting capture: \(snap.title.prefix(60))")
            let journalPage = LogseqClient.journalPageName()
            let inboxUUID = try await logseq.findOrCreateInboxBlock(
                journalPage: journalPage,
                inboxTitle: config.journalInboxTitle
            )
            let taskUUID = try await logseq.createCaptureTask(
                inboxBlockUUID: inboxUUID,
                title: snap.title,
                capturedExtId: snap.extId
            )
            // Carry the reminder's due date to Logseq as :scheduled (date-only
            // direction; we use the captured extId anchor, not a SyncPair).
            if config.syncDates, let dueMs = snap.dueComponents.flatMap({
                Mapper.dueComponentsToEpochMs($0)
            }) {
                try? await logseq.setBlockDate(
                    blockUUID: taskUUID, field: .scheduled, epochMs: dueMs)
            }
            // The Logseq-side captured-reminder-id property is the durable
            // idempotency anchor. No footer needed on the reminder.
            try await reminders.completeReminder(localId: snap.localId)
            state.captures.append(CaptureRecord(
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                journalBlockUUID: taskUUID
            ))
        }

        // Archive previously-ingested captures that weren't completed (crash recovery,
        // or user manually un-completed an archived capture).
        for (snap, cls) in classified {
            guard case .alreadyIngested = cls, !snap.isCompleted else { continue }
            logger.log("Completing stale capture: \(snap.title.prefix(60))")
            try await reminders.completeReminder(localId: snap.localId)
        }

        // ── Step 8: Persist ───────────────────────────────────────────────────
        state.lastRunDate = Date()
        stateStore.save(state)
        logger.log("Sync complete — \(state.pairs.count) pairs, \(state.captures.count) captures")
    }

    // MARK: - Private helpers

    /// Build the reminder title and notes for a Logseq block, applying the full
    /// transformation pipeline: resolve `[[uuid]]` page-refs → strip Logseq
    /// markup → strip remaining markdown → append `#lsq` tag to title.
    private func buildTitleAndNotes(
        blockTitle: String,
        childTitles: [String]
    ) async throws -> (title: String, notes: String) {
        var uuids: [String] = Mapper.extractPageRefUUIDs(blockTitle)
        for child in childTitles {
            uuids.append(contentsOf: Mapper.extractPageRefUUIDs(child))
        }
        let pageTitles = try await logseq.resolvePageTitles(uuids: uuids)

        let title = Mapper.plainText(blockTitle, pageTitles: pageTitles)
        let plainChildren = childTitles.map { Mapper.plainText($0, pageTitles: pageTitles) }
        let notes = Mapper.buildNotesString(childTitlesPlainText: plainChildren)

        return (title, notes)
    }

    private func ms(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Date 3-way merge

    private mutating func mergeDates(
        updated: SyncPair,
        block: LogseqBlock,
        live: ReminderSnapshot
    ) async throws -> SyncPair {
        var updated = updated
        let logseqDueMs  = (block.deadline ?? block.scheduled).map { Int64($0) }
        let logseqField  = Mapper.preferredDateField(deadline: block.deadline,
                                                     scheduled: block.scheduled)
        let reminderDueMs = live.dueComponents.flatMap { Mapper.dueComponentsToEpochMs($0) }

        // Initial observation after upgrade: both fields may be unset on the pair.
        // Write nothing; just record the current values as baseline.
        if updated.lastDueDateMs == nil {
            let baseline = logseqDueMs ?? reminderDueMs
            if let b = baseline {
                if let l = logseqDueMs, let r = reminderDueMs, l != r {
                    logger.log("Initial-upgrade date divergence for \(updated.logseqUUID.prefix(8))… — Logseq \(l), Reminder \(r) — both kept; next edit will resolve")
                }
                updated.lastDueDateMs = b
                updated.lastDueSource = logseqField
            }
            return updated
        }

        let logseqDateChanged   = logseqDueMs   != updated.lastDueDateMs
        let reminderDateChanged = reminderDueMs != updated.lastDueDateMs

        switch (logseqDateChanged, reminderDateChanged) {
        case (false, false):
            break  // no-op

        case (true, false):
            // Logseq changed → push to Reminders
            let logseqMs = block.updatedAt
            logger.log("Date Logseq→Reminders for \(updated.logseqUUID.prefix(8))…")
            if let newMs = logseqDueMs {
                try await reminders.setDueComponents(
                    localId: updated.reminderLocalId,
                    Mapper.epochMsToDueComponents(newMs))
            } else {
                try await reminders.clearDueComponents(localId: updated.reminderLocalId)
            }
            updated.lastDueDateMs = logseqDueMs
            updated.lastDueSource = logseqField
            _ = logseqMs

        case (false, true):
            // Reminders changed → push to Logseq
            let source = updated.lastDueSource ?? .scheduled
            logger.log("Date Reminders→Logseq for \(updated.logseqUUID.prefix(8))… field=\(source.rawValue)")
            if let newMs = reminderDueMs {
                try await logseq.setBlockDate(
                    blockUUID: updated.logseqUUID, field: source, epochMs: newMs)
                // If writing to scheduled but block has a deadline, clear the deadline
                // to avoid it masking the new value on the next pass.
                if source == .scheduled && block.deadline != nil {
                    try? await logseq.clearBlockDate(
                        blockUUID: updated.logseqUUID, field: .deadline)
                    updated.lastDueSource = .scheduled
                }
            } else {
                try await logseq.clearBlockDate(
                    blockUUID: updated.logseqUUID, field: source)
            }
            updated.lastDueDateMs = reminderDueMs
            if reminderDueMs == nil { updated.lastDueSource = nil }

        case (true, true):
            // Both changed — most-recent-wins
            let logseqMs    = block.updatedAt
            let reminderMs  = live.lastModified.map { ms($0) } ?? 0
            if logseqMs >= reminderMs {
                logger.log("Date CONFLICT \(updated.logseqUUID.prefix(8))…: Logseq wins")
                if let newMs = logseqDueMs {
                    try await reminders.setDueComponents(
                        localId: updated.reminderLocalId,
                        Mapper.epochMsToDueComponents(newMs))
                } else {
                    try await reminders.clearDueComponents(localId: updated.reminderLocalId)
                }
                updated.lastDueDateMs = logseqDueMs
                updated.lastDueSource = logseqField
            } else {
                logger.log("Date CONFLICT \(updated.logseqUUID.prefix(8))…: Reminder wins")
                let source = updated.lastDueSource ?? .scheduled
                if let newMs = reminderDueMs {
                    try await logseq.setBlockDate(
                        blockUUID: updated.logseqUUID, field: source, epochMs: newMs)
                } else {
                    try await logseq.clearBlockDate(
                        blockUUID: updated.logseqUUID, field: source)
                }
                updated.lastDueDateMs = reminderDueMs
                if reminderDueMs == nil { updated.lastDueSource = nil }
            }
        }

        return updated
    }

}
