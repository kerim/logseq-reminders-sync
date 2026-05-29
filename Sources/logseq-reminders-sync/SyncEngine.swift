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
        logger.log("Sync started — graph: \(config.graph)")

        // ── Step 3(a): Read prioritized tasks (Urgent/High/Medium, any status) ──
        let prioritizedTasks = try await logseq.fetchPrioritizedTasks()
        var prioritizedByUUID: [String: LogseqBlock] = [:]
        for t in prioritizedTasks { prioritizedByUUID[t.uuid] = t }
        logger.log("Prioritized tasks: \(prioritizedTasks.count)")

        // Pre-fetch property maps for confirm-guard and reindex guard.
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

        // ── Step 3(b): Fetch out-of-filter linked blocks ──────────────────────
        // Gate uses prioritizedByUUID (was doingByUUID) so blocks that moved off
        // priority are correctly identified as out-of-filter.
        var linkedStatus: [String: LogseqBlock?] = [:]
        for pair in state.pairs where prioritizedByUUID[pair.logseqUUID] == nil {
            linkedStatus[pair.logseqUUID] = try await logseq.fetchBlock(uuid: pair.logseqUUID)
        }

        // ── Step 3(c): Reindex guard ──────────────────────────────────────────
        // Gate uses prioritizedByUUID — a still-prioritized block whose UUID was
        // regenerated must have its pair's UUID corrected before teardown checks run.
        for i in state.pairs.indices {
            let pair = state.pairs[i]
            guard prioritizedByUUID[pair.logseqUUID] == nil else { continue }
            guard let found = linkedStatus[pair.logseqUUID], found == nil else { continue }
            if let newUUID = blockUUIDForExtId[pair.reminderExtId], newUUID != pair.logseqUUID {
                logger.log("Reindex: \(pair.logseqUUID.prefix(8))… → \(newUUID.prefix(8))…")
                linkedStatus[newUUID] = try await logseq.fetchBlock(uuid: newUUID)
                linkedStatus.removeValue(forKey: pair.logseqUUID)
                state.pairs[i].logseqUUID = newUUID
                await writeBacklink(localId: pair.reminderLocalId, blockUUID: newUUID)
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
        let completedSnaps  = try await reminders.fetchCompleted(since: lookback)
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
            if let idx = pairIndexByLocalId[snap.localId] {
                classified.append((snap, .linked(idx: idx))); continue
            }
            let extMatches = state.pairs.enumerated().filter { $0.element.reminderExtId == snap.extId }
            if extMatches.count == 1 {
                classified.append((snap, .linked(idx: extMatches[0].offset))); continue
            } else if extMatches.count > 1 {
                logger.log("WARN: Ambiguous extId \(snap.extId.prefix(8))…")
            }
            if archivedExtIdSet.contains(snap.extId) { skippedArchivedCount += 1; continue }
            if let blockUUID = blockUUIDForExtId[snap.extId] {
                classified.append((snap, .linkedRebuild(blockUUID: blockUUID))); continue
            }
            if let journalUUID = captureUUIDForExtId[snap.extId] {
                classified.append((snap, .alreadyIngested(journalUUID: journalUUID))); continue
            }
            // Only reminders in one of the 5 managed lists can be fresh captures.
            guard config.managedListIds.contains(snap.listId) else { continue }
            classified.append((snap, .fresh))
        }
        if skippedArchivedCount > 0 {
            logger.log("Skipped \(skippedArchivedCount) archived recurring-cycle reminder(s)")
        }

        // ── Step 4.5: Rebuild pairs from reminder-id property index ──────────
        var rebuiltLocalIds = Set<String>()
        for (snap, cls) in classified {
            guard case .linkedRebuild(let blockUUID) = cls else { continue }
            guard let block = try await logseq.fetchBlock(uuid: blockUUID) else {
                logger.log("Rebuild target \(blockUUID.prefix(8))… gone → deleting reminder")
                try await reminders.deleteReminder(localId: snap.localId)
                continue
            }

            // Guard: if the block has no status (never promoted), treat as incomplete
            // capture rather than rebuilding — a teardown would delete the user's reminder.
            guard let blockStatus = block.status else {
                logger.log("Rebuild target \(blockUUID.prefix(8))… has no status (incomplete capture) — re-promoting")
                let capturedPriority: LogseqPriority? = config.syncPriority
                    ? Mapper.reminderPriorityToLogseq(snap.priority) ?? .medium
                    : nil
                // Re-run the promote; ignore error (will retry next pass)
                let targetStatus = config.status(forListId: snap.listId) ?? "Todo"
                try? await logseq.updateTaskStatus(blockUUID: blockUUID, status: targetStatus)
                if let p = capturedPriority {
                    try? await logseq.setBlockPriority(blockUUID: blockUUID, priority: p)
                }
                continue
            }

            logger.log("Rebuilding pair: \(blockUUID.prefix(8))… ↔ reminder \(snap.localId.prefix(8))…")
            let logseqDone = Mapper.logseqStatusIsCompleted(blockStatus)
            let childTitles = try await logseq.fetchChildTitles(blockUUID: blockUUID)
            let (titleStr, notesStr) = try await buildTitleAndNotes(
                blockTitle: block.title, childTitles: childTitles)
            let logseqPrio = block.priority?.forSync
            let targetApplePrio = Mapper.logseqPriorityToReminder(logseqPrio)
            if config.syncPriority && targetApplePrio != snap.priority {
                logger.log("  → setting reminder priority \(targetApplePrio) to match Logseq")
                try? await reminders.setPriority(localId: snap.localId, targetApplePrio)
            }
            // Move reminder to the correct list if Logseq status doesn't match.
            if !logseqDone, let targetListId = config.listId(forStatus: blockStatus),
               snap.listId != targetListId {
                _ = try? await reminders.moveReminder(localId: snap.localId, toListId: targetListId)
            }
            let pair = SyncPair(
                logseqUUID: blockUUID,
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                lastStatus: blockStatus,
                lastOpenStatus: logseqDone ? "Doing" : blockStatus,
                lastCompleted: snap.isCompleted,
                lastLogseqUpdated: block.updatedAt,
                lastReminderMod: snap.lastModified.map { ms($0) },
                lastTitle: titleStr,
                lastNotesHash: Mapper.hashNotes(notesStr),
                lastPriority: config.syncPriority ? logseqPrio : nil)
            state.pairs.append(pair)
            if logseqDone && !snap.isCompleted {
                try await reminders.completeReminder(localId: snap.localId)
            } else if !logseqDone && snap.isCompleted {
                try? await reminders.updateReminder(localId: snap.localId, isCompleted: false)
            }
            rebuiltLocalIds.insert(snap.localId)
        }
        pairIndexByLocalId = [:]
        for (i, p) in state.pairs.enumerated() { pairIndexByLocalId[p.reminderLocalId] = i }

        // ── Step 5: Reconcile linked pairs ────────────────────────────────────
        let linkedLocalIds: Set<String> = Set(
            classified.compactMap { snap, cls -> String? in
                if case .linked = cls { return snap.localId }
                return nil
            } + rebuiltLocalIds
        )

        var pairsToRemove = Set<String>()

        for i in state.pairs.indices {
            let pair = state.pairs[i]
            let uuid = pair.logseqUUID

            if rebuiltLocalIds.contains(pair.reminderLocalId) { continue }

            // Block disposition
            let currentBlock: LogseqBlock?
            let isInFilter: Bool
            if let b = prioritizedByUUID[uuid] {
                currentBlock = b; isInFilter = true
            } else if let found = linkedStatus[uuid], let b = found {
                currentBlock = b; isInFilter = false
            } else {
                currentBlock = nil; isInFilter = false
            }

            if currentBlock == nil {
                logger.log("Block \(uuid.prefix(8))… deleted → deleting reminder")
                try await reminders.deleteReminder(localId: pair.reminderLocalId)
                pairsToRemove.insert(uuid); continue
            }

            let block = currentBlock!
            let currentStatus = block.status   // nil handled below

            guard let live = await reminders.fetchSnapshot(localId: pair.reminderLocalId) else {
                pairsToRemove.insert(uuid); continue
            }

            // ── F.2.1: Out-of-managed-lists opt-out ──────────────────────────
            // A reminder dragged to an unmanaged list is visible via fetchSnapshot
            // but config.status returns nil. Drop without touching Logseq — the
            // still-prioritized task gets a fresh reminder in Step 6 next run.
            if isInFilter, config.status(forListId: live.listId) == nil, !live.isCompleted {
                logger.log("Block \(uuid.prefix(8))… reminder dragged to unmanaged list → dropping pair")
                pairsToRemove.insert(uuid); continue
            }

            // Block left filter (priority no longer syncable)?
            if !isInFilter {
                // Any out-of-filter pair is due to priority loss (filter is priority-only).
                // Delete the reminder and drop the pair.
                logger.log("Block \(uuid.prefix(8))… left priority filter (\(currentStatus ?? "no-status")) → deleting reminder")
                try await reminders.deleteReminder(localId: pair.reminderLocalId)
                pairsToRemove.insert(uuid); continue
            }

            // Reminder gone from managed lists?
            if !linkedLocalIds.contains(pair.reminderLocalId) {
                logger.log("Reminder for \(uuid.prefix(8))… gone → dropping link (will re-mirror)")
                pairsToRemove.insert(uuid); continue
            }

            let extIdMatch = live.extId == pair.reminderExtId
            let propMatch  = blockUUIDForExtId[pair.reminderExtId] == uuid
            guard extIdMatch || propMatch else {
                logger.log("WARN: Confirm guard failed for \(uuid.prefix(8))… — skipping")
                continue
            }

            // ── Capture preWriteReminderMs before any write ───────────────────
            // This is the conflict operand for the DATE and PRIORITY axes.
            // The STATUS axis may use a synthesized now() for list-moves that
            // don't bump lastModifiedDate — scoped only to statusMergeAction.
            let preWriteReminderMs: Int64? = live.lastModified.map { ms($0) }

            var updated = pair

            // ── F.2.2: Recurring-completed rotation ───────────────────────────
            // Must run for EVERY in-filter pair (was wrongly gated on !isInFilter).
            // Use the broader condition matching the existing code (line 243).
            if block.isRecurring && (pair.lastCompleted || live.isCompleted) {
                if !state.archivedExtIds.contains(pair.reminderExtId) {
                    state.archivedExtIds.append(pair.reminderExtId)
                }
                logger.log("Recurring \(uuid.prefix(8))… cycle complete — pair dropped, reminder archived")
                pairsToRemove.insert(uuid); continue
            }

            // ── F.2.3: Priority-loss teardown ─────────────────────────────────
            // Unconditional Logseq-wins: Low is the explicit de-prioritize marker;
            // Logseq deliberately owns it — not a timestamp race to resolve.
            let logseqEffective = block.priority?.forSync
            if logseqEffective == nil {
                logger.log("Block \(uuid.prefix(8))… priority cleared in Logseq → deleting reminder")
                try await logseq.setBlockPriority(blockUUID: uuid, priority: .low)
                try await reminders.deleteReminder(localId: pair.reminderLocalId)
                pairsToRemove.insert(uuid); continue
            }

            // ── F.2.4: Priority 3-way merge (returns action enum) ────────────
            if config.syncPriority {
                let prioResult = try await mergePriority(
                    updated: updated, block: block, live: live, preWriteReminderMs: preWriteReminderMs)
                if case .appleCleared = prioResult {
                    // Apple cleared priority and won the conflict → set Logseq to Low and teardown.
                    logger.log("Block \(uuid.prefix(8))… Apple cleared priority → setting Logseq Low, deleting reminder")
                    try await logseq.setBlockPriority(blockUUID: uuid, priority: .low)
                    try await reminders.deleteReminder(localId: pair.reminderLocalId)
                    pairsToRemove.insert(uuid); continue
                }
                updated = prioResult.pair
            }

            // ── F.2.5: Unified status merge ───────────────────────────────────
            guard let blockStatus = currentStatus else {
                // Block has no status property — log and skip; never default to "Doing".
                logger.log("WARN: Block \(uuid.prefix(8))… has no status — skipping status merge")
                state.pairs[i] = updated; continue
            }
            let effectiveReminderStatus: String?
            if live.isCompleted {
                effectiveReminderStatus = "Done"
            } else {
                effectiveReminderStatus = config.status(forListId: live.listId)
            }
            guard let effStatus = effectiveReminderStatus else {
                // Should not reach here after F.2.1, but guard defensively.
                logger.log("WARN: Effective reminder status nil for \(uuid.prefix(8))… — skipping")
                state.pairs[i] = updated; continue
            }

            let logseqMs = block.updatedAt
            let action = Mapper.statusMergeAction(
                logseqStatus: blockStatus,
                effectiveReminderStatus: effStatus,
                lastStatus: pair.lastStatus,
                logseqMs: logseqMs,
                reminderMs: preWriteReminderMs,
                isRecurring: block.isRecurring)

            switch action {
            case .converged(let winningStatus):
                updated.lastStatus = winningStatus
                if !Mapper.logseqStatusIsCompleted(winningStatus) {
                    updated.lastOpenStatus = winningStatus
                }
                updated.lastCompleted = live.isCompleted
                updated.lastReminderMod = preWriteReminderMs
                updated.lastLogseqUpdated = logseqMs

            case .pushToReminder(let targetStatus):
                logger.log("Status \(pair.lastStatus)→\(targetStatus) for \(uuid.prefix(8))… (Logseq wins)")
                if targetStatus == "Done" {
                    try await reminders.completeReminder(localId: pair.reminderLocalId)
                } else {
                    // Uncomplete if currently completed, then move to target list.
                    if live.isCompleted {
                        _ = try await reminders.uncompleteReminder(localId: pair.reminderLocalId)
                    }
                    if let targetListId = config.listId(forStatus: targetStatus),
                       live.listId != targetListId {
                        if let moved = try await reminders.moveReminder(
                            localId: pair.reminderLocalId, toListId: targetListId) {
                            // Update identity from post-move snapshot (IDs may change on move).
                            updated.reminderLocalId = moved.localId
                            updated.reminderExtId   = moved.extId
                            if let fresh = await reminders.fetchSnapshot(localId: moved.localId) {
                                updated.lastReminderMod = fresh.lastModified.map { ms($0) }
                                updated.lastCompleted   = fresh.isCompleted
                            }
                        }
                    }
                }
                if updated.lastReminderMod == preWriteReminderMs {
                    // No post-write re-fetch yet — fetch now.
                    if let fresh = await reminders.fetchSnapshot(localId: updated.reminderLocalId) {
                        updated.lastReminderMod = fresh.lastModified.map { ms($0) }
                        updated.lastCompleted   = fresh.isCompleted
                    }
                }
                updated.lastStatus = targetStatus
                if !Mapper.logseqStatusIsCompleted(targetStatus) {
                    updated.lastOpenStatus = targetStatus
                }
                updated.lastLogseqUpdated = logseqMs

            case .pushToLogseq(let targetStatus):
                logger.log("Status \(pair.lastStatus)→\(targetStatus) for \(uuid.prefix(8))… (Reminder wins)")
                try await logseq.updateTaskStatus(blockUUID: uuid, status: targetStatus)
                if let fresh = try await logseq.fetchBlock(uuid: uuid) {
                    updated.lastLogseqUpdated = fresh.updatedAt
                    let newStatus = fresh.status ?? targetStatus
                    updated.lastStatus = newStatus
                    if !Mapper.logseqStatusIsCompleted(newStatus) { updated.lastOpenStatus = newStatus }
                }
                updated.lastReminderMod = preWriteReminderMs
                updated.lastCompleted   = live.isCompleted

            case .recurringDeferred:
                // F.2.2 should have handled recurring completion above.
                // This is a belt-and-suspenders: recurring block + reminder completed
                // but F.2.2 guard condition not met — skip rather than push Done to Logseq.
                logger.log("Recurring \(uuid.prefix(8))… status deferred (recurring guard)")
                updated.lastCompleted = live.isCompleted
                updated.lastReminderMod = preWriteReminderMs
            }

            // ── Text/notes sync (one-way Logseq → Reminders) ────────────────
            let childTitles = try await logseq.fetchChildTitles(blockUUID: uuid)
            let (newTitle, newNotes) = try await buildTitleAndNotes(
                blockTitle: block.title, childTitles: childTitles)
            let notesHash = Mapper.hashNotes(newNotes)
            if newTitle != updated.lastTitle || notesHash != updated.lastNotesHash {
                try? await reminders.updateReminder(
                    localId: updated.reminderLocalId, title: newTitle, notes: newNotes)
                updated.lastTitle = newTitle
                updated.lastNotesHash = notesHash
                // Don't update lastReminderMod from a text write — the pre-write live
                // stays as the conflict operand for date/priority on this pass.
            }

            // ── Date merge (uses pre-write live for timestamp operand) ────────
            if config.syncDates {
                updated = try await mergeDates(
                    updated: updated, block: block, live: live,
                    preWriteReminderMs: preWriteReminderMs)
            }

            // Priority merge already ran above (F.2.4); just ensure baseline updated.
            // (mergePriority mutates updated.lastPriority in place when not .appleCleared)

            state.pairs[i] = updated
        }

        state.pairs.removeAll { pairsToRemove.contains($0.logseqUUID) }

        // ── Step 6: Mirror new open+prioritized tasks ─────────────────────────
        // Skip Done and Canceled at creation (requirement 5).
        // Note: logseqStatusIsCompleted only covers Done now; Canceled is an open
        // status but must also be excluded from creation — only the four open-and-mirrored
        // statuses (Backlog/Todo/Doing/In Review) should spawn new reminders.
        // Also exclude pairsToRemove so an appleCleared teardown in this same pass
        // doesn't immediately re-create the reminder with the stale Logseq snapshot.
        let pairedUUIDs = Set(state.pairs.map { $0.logseqUUID }).union(pairsToRemove)
        for mirrorBlock in prioritizedTasks where !pairedUUIDs.contains(mirrorBlock.uuid) {
            guard let blockStatus = mirrorBlock.status else { continue }
            guard LogseqStatus(rawTitle: blockStatus)?.isOpen == true else { continue }  // skip Done/Canceled
            guard let targetListId = config.listId(forStatus: blockStatus) else {
                logger.log("WARN: No list for status '\(blockStatus)' — skipping mirror of \(mirrorBlock.uuid.prefix(8))…")
                continue
            }
            guard mirrorBlock.priority?.forSync != nil else { continue }  // gate: syncable priority

            logger.log("Mirroring \(mirrorBlock.uuid.prefix(8))…: \(mirrorBlock.title.prefix(60))")
            let childTitles = try await logseq.fetchChildTitles(blockUUID: mirrorBlock.uuid)
            let (title, notes) = try await buildTitleAndNotes(
                blockTitle: mirrorBlock.title, childTitles: childTitles)
            let hash = Mapper.hashNotes(notes)
            let dueDateMs = (mirrorBlock.deadline ?? mirrorBlock.scheduled).map { Int64($0) }
            let dueSource = Mapper.preferredDateField(
                deadline: mirrorBlock.deadline, scheduled: mirrorBlock.scheduled)
            let dueComponents: DateComponents? = config.syncDates ? dueDateMs.map {
                Mapper.epochMsToDueComponents($0) } : nil
            let logseqPrio = mirrorBlock.priority?.forSync
            let initialPriority = config.syncPriority
                ? Mapper.logseqPriorityToReminder(logseqPrio) : 0
            let snap = try await reminders.createReminder(
                title: title, notes: notes, dueComponents: dueComponents,
                priority: initialPriority, inListId: targetListId)
            await writeBacklink(localId: snap.localId, blockUUID: mirrorBlock.uuid)
            try await logseq.setReminderIdProperty(blockUUID: mirrorBlock.uuid, extId: snap.extId)
            let pair = SyncPair(
                logseqUUID: mirrorBlock.uuid,
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                lastStatus: blockStatus,
                lastOpenStatus: blockStatus,
                lastCompleted: snap.isCompleted,
                lastLogseqUpdated: mirrorBlock.updatedAt,
                lastReminderMod: snap.lastModified.map { ms($0) },
                lastTitle: title,
                lastNotesHash: hash,
                lastDueDateMs: config.syncDates ? dueDateMs : nil,
                lastDueSource: config.syncDates ? dueSource : nil,
                lastPriority: config.syncPriority ? logseqPrio : nil)
            state.pairs.append(pair)
        }

        // ── Step 7: Adopt fresh reminders as mirror pairs ─────────────────────
        // New model: a reminder created directly in one of the 5 managed lists
        // becomes a live mirror pair (not a one-shot capture+complete).
        let knownCapExtIds = Set(state.captures.map { $0.reminderExtId })
        for (snap, cls) in classified {
            guard case .fresh = cls else { continue }
            // Skip if already recorded in state (old captured-reminder-id path)
            if knownCapExtIds.contains(snap.extId) { continue }
            // Skip if reminder-id block already created (partial adopt — will rebuild next pass)
            if blockUUIDForExtId[snap.extId] != nil { continue }
            // Must be in a managed list
            guard let statusForList = config.status(forListId: snap.listId) else { continue }

            logger.log("Adopting new reminder as mirror: \(snap.title.prefix(60))")
            let journalPage = LogseqClient.journalPageName()
            let captureTarget: CaptureTarget
            if let inboxTitle = config.journalInboxTitle {
                let inboxUUID = try await logseq.findOrCreateInboxBlock(
                    journalPage: journalPage, inboxTitle: inboxTitle)
                captureTarget = .inboxBlock(uuid: inboxUUID)
            } else {
                captureTarget = .journalPage(name: journalPage)
            }

            // Priority: carry from reminder; if none, default to Medium (Option 1).
            let capturedPriority: LogseqPriority?
            if config.syncPriority {
                capturedPriority = Mapper.reminderPriorityToLogseq(snap.priority) ?? .medium
            } else {
                capturedPriority = nil
            }

            // Write reminder-id ATOMICALLY in the block creation upsert (not a separate call).
            // Status matches the list the reminder was created in.
            let taskUUID = try await logseq.createCaptureTask(
                target: captureTarget,
                title: snap.title,
                reminderExtId: snap.extId,
                status: statusForList,
                priority: capturedPriority)

            // If reminder had no priority, also write Medium back to the reminder so
            // both sides agree at pair seeding — preventing the next priority-merge
            // from seeing "Apple cleared priority" and tearing the pair down.
            var freshSnap = snap
            if config.syncPriority && Mapper.reminderPriorityToLogseq(snap.priority) == nil {
                try? await reminders.setPriority(
                    localId: snap.localId, Mapper.logseqPriorityToReminder(.medium))
                if let refetched = await reminders.fetchSnapshot(localId: snap.localId) {
                    freshSnap = refetched   // seed lastReminderMod from post-write snapshot
                }
            }

            if config.syncDates, let dueMs = snap.dueComponents.flatMap({
                Mapper.dueComponentsToEpochMs($0) }) {
                try? await logseq.setBlockDate(
                    blockUUID: taskUUID, field: .scheduled, epochMs: dueMs)
            }

            // Do NOT complete the source reminder — it stays as a live mirror.
            await writeBacklink(localId: snap.localId, blockUUID: taskUUID)

            // Seed full baseline so the next reconcile lands on .converged.
            let dueDateMs = snap.dueComponents.flatMap { Mapper.dueComponentsToEpochMs($0) }
            let seededPriority: LogseqPriority? = config.syncPriority ? capturedPriority : nil
            let pair = SyncPair(
                logseqUUID: taskUUID,
                reminderLocalId: snap.localId,
                reminderExtId: snap.extId,
                lastStatus: statusForList,
                lastOpenStatus: statusForList,
                lastCompleted: false,
                lastLogseqUpdated: 0,  // fresh block; will update on next pass
                lastReminderMod: freshSnap.lastModified.map { ms($0) },
                lastTitle: snap.title,
                lastNotesHash: Mapper.hashNotes(""),
                lastDueDateMs: config.syncDates ? dueDateMs : nil,
                lastDueSource: config.syncDates ? .scheduled : nil,
                lastPriority: config.syncPriority ? seededPriority?.forSync : nil)
            state.pairs.append(pair)
        }

        // Archive previously-ingested captures that weren't completed (crash recovery).
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

    private func writeBacklink(localId: String, blockUUID: String) async {
        guard let backlink = Mapper.logseqDeepLink(graph: config.graph, blockUUID: blockUUID) else {
            logger.log("WARN: could not build backlink URL for \(blockUUID.prefix(8))…")
            return
        }
        if await reminders.setURLAttachment(localId: localId, url: backlink) == .failed {
            logger.log(
                "WARN: backlink not written for \(blockUUID.prefix(8))… " +
                "— REMURLAttachment save returned failure. See ReminderKitBridge.m"
            )
        }
    }

    private func buildTitleAndNotes(
        blockTitle: String,
        childTitles: [String]
    ) async throws -> (title: String, notes: String) {
        var uuids = Mapper.extractPageRefUUIDs(blockTitle)
        for child in childTitles { uuids.append(contentsOf: Mapper.extractPageRefUUIDs(child)) }
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

    /// `preWriteReminderMs` is captured before any reminder write this pass.
    /// The date merge uses it (not a post-write re-fetched value) so a same-pass
    /// status write doesn't contaminate the date conflict tie-break.
    private mutating func mergeDates(
        updated: SyncPair,
        block: LogseqBlock,
        live: ReminderSnapshot,
        preWriteReminderMs: Int64?
    ) async throws -> SyncPair {
        var updated = updated
        let logseqDueMs  = (block.deadline ?? block.scheduled).map { Int64($0) }
        let logseqField  = Mapper.preferredDateField(deadline: block.deadline,
                                                     scheduled: block.scheduled)
        let reminderDueMs = live.dueComponents.flatMap { Mapper.dueComponentsToEpochMs($0) }

        if updated.lastDueDateMs == nil {
            let baseline = logseqDueMs ?? reminderDueMs
            if let b = baseline {
                if let l = logseqDueMs, let r = reminderDueMs, l != r {
                    logger.log(
                        "Initial-upgrade date divergence for \(updated.logseqUUID.prefix(8))…" +
                        " — Logseq \(l), Reminder \(r) — both kept; next edit will resolve")
                }
                updated.lastDueDateMs = b
                updated.lastDueSource = logseqField
            }
            return updated
        }

        let logseqDateChanged   = logseqDueMs   != updated.lastDueDateMs
        let reminderDateChanged = reminderDueMs != updated.lastDueDateMs

        switch (logseqDateChanged, reminderDateChanged) {
        case (false, false): break

        case (true, false):
            logger.log("Date Logseq→Reminders for \(updated.logseqUUID.prefix(8))…")
            if let newMs = logseqDueMs {
                try await reminders.setDueComponents(
                    localId: updated.reminderLocalId, Mapper.epochMsToDueComponents(newMs))
            } else {
                try await reminders.clearDueComponents(localId: updated.reminderLocalId)
            }
            updated.lastDueDateMs = logseqDueMs
            updated.lastDueSource = logseqField

        case (false, true):
            let source = updated.lastDueSource ?? .scheduled
            logger.log("Date Reminders→Logseq for \(updated.logseqUUID.prefix(8))… field=\(source.rawValue)")
            if let newMs = reminderDueMs {
                try await logseq.setBlockDate(
                    blockUUID: updated.logseqUUID, field: source, epochMs: newMs)
                if source == .scheduled && block.deadline != nil {
                    try? await logseq.clearBlockDate(blockUUID: updated.logseqUUID, field: .deadline)
                    updated.lastDueSource = .scheduled
                }
            } else {
                try await logseq.clearBlockDate(blockUUID: updated.logseqUUID, field: source)
            }
            updated.lastDueDateMs = reminderDueMs
            if reminderDueMs == nil { updated.lastDueSource = nil }

        case (true, true):
            let logseqMs   = block.updatedAt
            let reminderMs = preWriteReminderMs ?? 0   // pre-write operand
            if logseqMs >= reminderMs {
                logger.log("Date CONFLICT \(updated.logseqUUID.prefix(8))…: Logseq wins")
                if let newMs = logseqDueMs {
                    try await reminders.setDueComponents(
                        localId: updated.reminderLocalId, Mapper.epochMsToDueComponents(newMs))
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
                    try await logseq.clearBlockDate(blockUUID: updated.logseqUUID, field: source)
                }
                updated.lastDueDateMs = reminderDueMs
                if reminderDueMs == nil { updated.lastDueSource = nil }
            }
        }
        return updated
    }

    // MARK: - Priority 3-way merge (returns action enum)

    enum PriorityMergeResult {
        case noChange(SyncPair)
        case pushedToApple(SyncPair)
        case pushedToLogseq(SyncPair)
        /// Apple cleared priority and won the conflict.
        /// Caller must set Logseq to Low and delete+drop the pair.
        case appleCleared(SyncPair)

        var pair: SyncPair {
            switch self {
            case .noChange(let p), .pushedToApple(let p),
                 .pushedToLogseq(let p), .appleCleared(let p): return p
            }
        }
    }

    private mutating func mergePriority(
        updated: SyncPair,
        block: LogseqBlock,
        live: ReminderSnapshot,
        preWriteReminderMs: Int64?
    ) async throws -> PriorityMergeResult {
        var updated = updated
        let logseqEffective = block.priority?.forSync
        let appleBucketed   = Mapper.reminderPriorityToLogseq(live.priority)

        if logseqEffective == nil && appleBucketed == nil && updated.lastPriority == nil {
            return .noChange(updated)
        }

        let logseqChanged = logseqEffective != updated.lastPriority
        let appleChanged  = appleBucketed   != updated.lastPriority

        switch (logseqChanged, appleChanged) {
        case (false, false):
            return .noChange(updated)

        case (true, false):
            let target = Mapper.logseqPriorityToReminder(logseqEffective)
            logger.log("Priority Logseq→Reminders for \(updated.logseqUUID.prefix(8))… target=\(target)")
            if target != live.priority {
                try await reminders.setPriority(localId: updated.reminderLocalId, target)
            }
            updated.lastPriority = logseqEffective
            return .pushedToApple(updated)

        case (false, true):
            logger.log("Priority Reminders→Logseq for \(updated.logseqUUID.prefix(8))… bucket=\(appleBucketed?.rawValue ?? "none")")
            if appleBucketed == nil {
                // Apple cleared priority — signal teardown to caller.
                return .appleCleared(updated)
            }
            try await applyPriorityToLogseq(appleBucketed, blockUUID: updated.logseqUUID)
            updated.lastPriority = appleBucketed
            return .pushedToLogseq(updated)

        case (true, true):
            let logseqMs   = block.updatedAt
            let reminderMs = preWriteReminderMs ?? 0   // pre-write operand
            logger.log("Priority CONFLICT \(updated.logseqUUID.prefix(8))…: \(logseqMs >= reminderMs ? "Logseq" : "Reminder") wins")
            if logseqMs >= reminderMs {
                let target = Mapper.logseqPriorityToReminder(logseqEffective)
                if target != live.priority {
                    try await reminders.setPriority(localId: updated.reminderLocalId, target)
                }
                updated.lastPriority = logseqEffective
                return .pushedToApple(updated)
            } else {
                if appleBucketed == nil {
                    // Apple wins AND Apple cleared priority → teardown.
                    return .appleCleared(updated)
                }
                try await applyPriorityToLogseq(appleBucketed, blockUUID: updated.logseqUUID)
                updated.lastPriority = appleBucketed
                return .pushedToLogseq(updated)
            }
        }
    }

    private func applyPriorityToLogseq(_ priority: LogseqPriority?, blockUUID: String) async throws {
        if let p = priority {
            try await logseq.setBlockPriority(blockUUID: blockUUID, priority: p)
        } else {
            try await logseq.clearBlockPriority(blockUUID: blockUUID)
        }
    }
}
