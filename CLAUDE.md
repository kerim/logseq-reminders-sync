# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS 14+ command-line tool that bi-directionally syncs Logseq DB-graph tasks (priority `Urgent`/`High`/`Medium`, any status) with five Apple Reminders lists — one per Logseq status. Each invocation runs one sync pass and exits — no daemon. Designed to be triggered on a schedule (cron / launchd).

## When to ask the user to test

**Never ask the user to test while a reviewer agent is still pending or while there are known unfixed bugs in the installed binary.** Before asking the user to test:

1. All reviewer agents have returned and their findings are addressed.
2. All fixes are implemented, tests pass, and the installed binary is clean.

Commit timing is separate — testing before committing is fine once the above are met.

## Build, sign, install, test

```fish
swift build                          # debug
swift build -c release               # release
bash scripts/sign.sh                 # signs .build/debug binary, installs to ~/.local/bin/
bash scripts/sign.sh release         # signs release binary
swift test                           # all tests
swift test --filter MapperTests      # single suite
swift test --filter MapperTests.pageLinksUnwrapped  # single test
```

**Code signing is not optional.** The binary uses `EKEventStore.requestFullAccessToReminders()`, which is TCC-gated by code-signing identity. An unsigned (or freshly re-signed) binary will be treated as a different app and prompt for Reminders permission again. The repo's signing identity is created once via `scripts/create-signing-cert.sh` (self-signed cert in the login keychain, identifier `com.kerim.logseq-reminders-sync`). Losing that cert means re-granting Reminders access.

`xcodebuild` is not used — this is a pure Swift Package Manager project. Don't invoke `XcodeBuildMCP` tools here.

## Bump the build number on every build

`App.buildVersion` (Sources/logseq-reminders-sync/App.swift) is a string constant printed by `--version`. Bump it before every `swift build` you intend to install. Never reuse a number.

## Package layout

Three SPM targets:

- **SyncCore** (library, `Sources/SyncCore/`) — pure data + transforms: `Config`, `SyncState`/`SyncPair`/`CaptureRecord`, `ReminderSnapshot`, `LogseqBlock`, `Mapper`, `StateStore`. No EventKit, no Process, no I/O beyond the state JSON file. This is what `Tests/SyncCoreTests/` exercises with Swift Testing.
- **ReminderKitBridge** (Objective-C library, `Sources/ReminderKitBridge/`) — reaches Apple's private `ReminderKit` framework via runtime introspection to write/read the `REMURLAttachment` that Reminders.app displays in its URL field. The public `EKCalendarItem.url` is disconnected from that field (confirmed macOS 26). See the private-symbol inventory and repair guide at the top of `ReminderKitBridge.m`.
- **logseq-reminders-sync** (executable, `Sources/logseq-reminders-sync/`) — everything that talks to the outside world: `App` (entry), `SyncEngine` (the 3-way merge), `LogseqClient` (shells out to the `logseq` CLI), `RemindersStore` (actor over `EKEventStore`), `Lockfile`, `RunLogger`. The Info.plist is embedded via `-sectcreate` linker flags so the CLI binary carries `NSRemindersFullAccessUsageDescription`.

## How the sync model works (the part that requires reading multiple files)

Read `SyncEngine.run()` top-to-bottom — it's the source of truth. The shape:

1. **Logseq is queried via the bundled `logseq` CLI** at `/Users/niyaro/.local/bin/logseq` (hardcoded in `App.cliPath`). All queries are Datascript EDN passed to `logseq query`; writes use `logseq upsert block/task/property`. `LogseqClient.bootstrap()` upserts the two custom properties (`reminder-id`, `captured-reminder-id`) and resolves their `:db/ident` keywords — every subsequent property read/write uses those resolved idents.

2. **The idempotency anchors live in Logseq, not in state.json.** Each mirrored Logseq block carries `reminder-id` = the reminder's `calendarItemExternalIdentifier` (extId). Each captured journal block carries `captured-reminder-id` = the source reminder's extId. The state file is a performance cache and is rebuildable from those properties — see Steps 3(c) "Reindex guard" and 4.5 "Rebuild pairs" in `SyncEngine.run()`.

3. **Two flows, one engine:**
   - **Mirror flow** (Logseq → Reminders): every task with priority `Urgent`/`High`/`Medium` and an open, mirrored status (Backlog/Todo/Doing/In Review) gets a reminder created in the matching status list; its extId is written back to the block as `reminder-id`. The reminder's list membership represents status — moving a reminder between lists pushes the new status back to Logseq. Three independent axes propagate bidirectionally via 3-way merge: **status** (via list membership), **dates** (`lastDueDateMs` / `lastDueSource`, gated by `syncDates`), and **priority** (`lastPriority`, gated by `syncPriority`). Title and child-block text propagate one-way (Logseq → Reminders notes). A block whose priority drops to `Low` or `nil` has its reminder deleted (priority-loss teardown).
   - **Adopt flow** (Reminders → Logseq): a reminder created directly in one of the five managed lists (no matching `reminder-id` anywhere) is adopted as a live mirror pair — a `Todo` block created under today's journal inbox with `reminder-id` written atomically. The reminder stays live (not completed). Priority and due date carry over at capture time when their respective config toggles are on.

4. **Conflict resolution** is most-recent-wins by `:block/updated-at` (ms) vs. `EKReminder.lastModifiedDate` (ms). Ties fold into Logseq-wins so single-field baselines stay convergent. `lastOpenStatus` is preserved so un-completing a reminder restores the right open status (`Doing`/`Todo`/`Backlog`/`In Review`) rather than always defaulting to `Doing`.

   **Priority bucketing.** Logseq has 4 priority levels (`Urgent`/`High`/`Medium`/`Low`); Apple Reminders uses RFC 5545 ints (1=High, 5=Medium, 9=Low, 0=none) with intra-bucket ranges. `Mapper.logseqPriorityToReminder` shifts one step down (`Urgent→1`, `High→5`, `Medium→9`, `Low→0`); the reverse mapping buckets `1...4→.urgent`, `5...8→.high`, `9→.medium`. Logseq `Low` is treated as "no priority" (normalized via `LogseqPriority.forSync`) and never appears on the reverse path. Comparisons in `mergePriority` happen in Logseq enum space so Apple's intra-bucket drift (e.g. 5→7) doesn't trigger spurious change signals.

5. **Text transformation pipeline** (`Mapper.plainText`): resolve `[[uuid]]` page-refs to titles via Logseq query → strip `[[Page]]` wrappers / `#tags` / `((block-refs))` → run through Foundation's markdown parser to drop `**bold**` / `*italic*` / `` `code` `` / `[label](url)`. Child blocks of the task become reminder notes, one line each. This is in `SyncCore` and is what most tests cover.

## Runtime files (outside the repo)

The binary reads and writes only under `~/.logseq-reminders-sync/`:

- `config.json` — `graph`, `statusLists` (map from status name to `{id, title}` for each of the 5 managed lists), `journalInboxTitle`, `fallbackInboxPage`, `conflictPolicy`, `syncDates` (opt-in, default `false`; reads legacy `syncDeadlines` if present), `syncPriority` (opt-out, default `true`). Decoded by `Config.load()`. Legacy keys `remindersListId`/`remindersListTitle`/`filterQueryFile` are silently accepted but ignored — migrate to `statusLists`.
- `state.json` — `SyncState` (pairs + captures + lastRunDate). Pretty-printed, sorted keys, atomic writes.
- `log/YYYY-MM-DD.log` — daily run log, also tee'd to stdout via `RunLogger`.
- `lock` — PID file; `Lockfile.acquire()` uses `kill(pid, 0)` to test liveness, so stale lockfiles from crashes are auto-recovered.

## Diagnostic CLI flags

When debugging without mutating either side:

- `--dump-reminders` — lists all reminder lists, marks the configured one, dumps incomplete + last-7-days-completed reminders.
- `--dump-tasks` — bootstraps the Logseq client, prints the resolved property idents, dumps prioritized tasks (Urgent/High/Medium, any status).

These are read-only and skip the lockfile / state writes — useful for verifying config and Logseq CLI connectivity.

One maintenance flag *does* write:

- `--backfill-links` — writes the Logseq backlink (`logseq://graph/<graph>?block-id=<uuid>`) into the Reminders.app URL field of every already-paired mirror reminder, via the private `ReminderKit` bridge (`RemindersStore.setURLAttachment`). For reminders created before build 19; newer ones get the link at creation time, and the reindex guard in `SyncEngine.run()` rewrites it when a block's UUID changes. Rebuilt pairs (Step 4.5) and pairs that left the Doing filter without a UUID change are not covered in-run — run `--backfill-links` after a state rebuild or upgrade. Unlike the `--dump-*` flags it acquires the lockfile and authorizes Reminders, but it does **not** write `state.json`. Reports four buckets: written / already current / failed / missing. Any `failed` count means the private API may have changed — see `ReminderKitBridge.m`.

## Conventions worth respecting

- **Swift Testing**, not XCTest. Use `@Suite` / `@Test` / `#expect`.
- `SyncCore` must stay free of `EventKit`, `Process`, and any other host-only imports — that's what keeps it unit-testable.
- The `BUILD ≤8` comments in `Mapper` (`extractMirrorUUID` / `extractCaptureUUID`) are intentional back-compat for an older state format that wrote `logseq-id:` / `logseq-captured:` footers into reminder notes. Don't rip them out — they're only invoked on old data.
- Errors surface to the user via `LocalizedError.errorDescription`. When adding new error cases, write the message for the user, not for the log.
