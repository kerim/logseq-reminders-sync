# Changelog

## Build 46 — 2026-06-30

### Fixed
- **A reminder's notes body is now imported when the reminder is adopted into Logseq.** When you create a reminder directly in one of the five managed lists (Todo, Doing, etc.), it is turned into a Logseq task. Previously the task appeared with just the title — the body text was silently dropped. It now arrives as indented child blocks under the task, one per paragraph. Subsequent syncs leave the body untouched and do not push anything back to Reminders.

---

## Build 45 — 2026-06-14

### Fixed
- **Reminder text with quotation marks or backslashes no longer gets silently lost on import.** A note or task whose text contained a `"` (e.g. `Bring "17+1" teachers`) would have its write to Logseq truncated at the quote, dropping the rest. All user text written into Logseq properties is now escaped correctly first.
- **List items in a shared note no longer show a doubled bullet.** Apple Reminders writes list lines as `- text` (or `- 1. text` for numbered lists); since every Logseq block is already a bullet, the leading `- ` is now stripped on import so items don't appear as `- - text`.
- **A note line that starts with a dash is no longer mistaken for a command option.** Note body lines beginning with `-` were being misread as flags by the Logseq command-line tool; arguments are now passed in a form that can't be confused with options.
- **Deleting an imported note in Logseq now lets it re-import.** Previously, once a note was imported the tool remembered it forever and would never bring it back even if you deleted it. The tool now notices when an imported note's anchor is gone from the graph and re-imports the note on the next pass — useful for forcing a clean re-import.

### Changed
- **A note import that fails partway through now rolls back cleanly.** If the title block is created but a body paragraph fails to write, the half-imported note is removed so the next sync pass retries from scratch instead of leaving a stub that could never complete.

---

## Build 40 — 2026-06-06

### Added
- **`pause` and `resume` commands.** `pause` durably disables the background agent so it stays off across logout and reboot (`launchctl disable` + `bootout`); `resume` re-enables and restarts it. Replaces the manual `launchctl` steps for everyday pause/resume.
- **`uninstall` command.** Removes the tool in one step after a typed confirmation: stops and removes the background agent, deletes the six managed Reminders lists and all reminders in them, strips `reminder-id` / `captured-reminder-id` markers from the Logseq graph, removes the binary, clears the local data directory (`~/.logseq-reminders-sync/`), and removes the signing certificate from the login keychain.

### Changed
- `LaunchdAgent.reload()` now calls `enable()` before `bootstrap()`, so re-installing the agent after a durable `pause` correctly re-enables the label. Previously, `bootstrap` was silently refused while the label was disabled.

---

## Build 39 — 2026-06-02

### Added
- **Update notifications.** The tool now checks GitHub Releases once a day and shows a macOS notification banner when a newer build is available (e.g. "Build 40 is available (you have 39)."). The check is throttled to at most once per 24 hours, notifies at most once per newly-seen build, and silently steps aside if the network or GitHub is unavailable — it can never slow down or break a sync pass.
- `--check-update` flag: immediately checks for a newer release, bypassing the 24-hour throttle. Always re-shows the banner if a newer build exists (useful for testing or manually confirming you're up to date).
- `scripts/release.sh`: a `gh`-based helper that reads the current `buildVersion` from `App.swift`, extracts the matching `CHANGELOG.md` section, and publishes a GitHub release tagged `build-N`. Includes idempotency guard (aborts if the tag already exists) and anchored awk matching to avoid build-number prefix collisions.
- `~/.logseq-reminders-sync/update-check.json`: small state file tracking the last check timestamp and last notified build. Siblings `state.json` and `config.json`.

---

## Build 38 — 2026-06-02

### Fixed
- **Checking a recurring task complete in Reminders now advances the Logseq task to its next scheduled date.** Previously, the sync would archive the reminder and drop the pair without ever telling Logseq the cycle was done — so the task stayed on its current date indefinitely. The sync now tells Logseq "done" (which causes Logseq to advance the date and reset the task to Todo), then reuses the same reminder by unchecking it and rolling its due date and list forward to match — identical to what happens when you complete the task inside Logseq.

### Changed
- Recurring task completion is now handled with a two-phase error structure. Phase A writes Done to Logseq; on failure it re-completes the reminder so the next sync pass retries automatically. Phase B rolls the reminder forward; on failure it degrades gracefully without re-completing, so the next pass's normal date/list merge reconciles without a second advance.

---

## Build 37 — 2026-06-02

### Fixed
- **Sync no longer fails to find today's journal page.** The tool was guessing the journal title from a hardcoded list of full month names ("June 2nd, 2026"), but Logseq stored the page as "Jun 2nd, 2026" — causing a `page-not-found` error on every Reminders→Logseq capture. The title is now looked up from the graph by date (`:block/journal-day`), which is format-agnostic and works regardless of how any user's graph formats journal titles.

### Added
- `JournalRenderer` (pure, unit-tested) — a longest-match tokenizer for date-fns/Unicode TR35 format strings that renders `"MMM do, yyyy"` → `"Jun 2nd, 2026"`. Handles full-month (`MMMM`), weekday (`EEE`/`EEEE`), ordinal day (`do`), quoted literals, and safely degrades to `nil` on unrecognized tokens. 15 Swift Testing unit tests cover all ordinal edges, timezone boundary, quoted literals, and the degrade path.
- When no journal exists for today (scheduled sync fires before Logseq opens), the sync logs a clear message and skips only the affected capture — the rest of the pass completes and the baseline is saved. The skipped reminder retries on the next run.

### Changed
- Captures that fail to resolve today's journal page are now **skipped per-item** rather than aborting the entire sync pass. Previously, a single missing journal would silently drop all remaining captures *and* all baseline-persistence progress for that run.

---

## Build 35 — 2026-05-31

### Added
- **Shared web URLs survive import as clickable Markdown links.** When you share a web page into any of the managed Reminders lists (or the Logseq Notes list), the page title and URL are now turned into a Markdown link `[page title](page url)` in the imported Logseq block, instead of plain title text. For status-list reminders the reminder's URL field is still replaced by a Logseq backlink afterward (only one URL slot is available); the web URL is preserved inside Logseq as a live link. One-way note imports keep both the link and the original URL field.
- `Mapper.linkifyImportedTitle(title:url:)` — pure helper that builds `[escapedTitle](url)`. Ignores nil, empty, whitespace, and `logseq:` URLs (case-insensitive prefix check). Backslash-escapes `\`, `[`, `]`, `#` in the label (backslash first) so the link label can't break the markdown parser and `#token` isn't tag-parsed by Logseq.
- `RemindersStore.readURLAttachment(localId:)` — reads the private `REMURLAttachment` field (what Reminders.app shows) at capture time, before `writeBacklink` overwrites it.

### Changed
- `SyncPair.lastTitle` at adoption is now seeded from `Mapper.plainText(content, pageTitles: [:])` rather than `snap.title`. Since the newly-created block content is `[label](url)` with no `[[uuid]]` page refs, this equals exactly what Step 5's reconcile will recompute on the next pass — so no spurious title write occurs regardless of what characters the title contains.

---

## Build 33 — 2026-05-30

### Added
- **One-way note capture via a new "Logseq Notes" list.** A sixth Reminders list, created by `setup`, imports reminders into Logseq as plain notes: the title becomes a top-level block on today's journal and each paragraph of the note becomes a nested block beneath it (blank lines dropped). Notes get **no task status**, the source reminder is **marked complete** after import, and the import is strictly **one-way** — notes are never synced back, and deleting the reminder afterwards leaves the Logseq note untouched (unlike a task, whose reminder would reappear). Idempotency uses a separate hidden `captured-reminder-id` property, distinct from the two-way `reminder-id` link.
- `notesList` config field (`{id, title}`). Absent in configs predating this feature, in which case note capture is inactive — existing setups are unaffected until they re-run `setup`.

### Changed
- `switch-graph` now also empties and verifies the **Logseq Notes** list as part of its full clean.
- Internal: extracted `CaptureTarget.cliArgs` and `LogseqClient.todaysCaptureTarget(…)` to remove duplication shared between the task-adopt and note-import flows.

---

## Build 31 — 2026-05-29

### Changed
- Internal: `Mapper.dateMergeAction` now bundles each date with its Logseq field (`scheduled`/`deadline`) into a small `SourcedDate` value, dropping it to within the existing 6-parameter lint limit. The previous build had raised that limit instead; that change is reverted. No behavior change.

---

## Build 30 — 2026-05-29

### Fixed
- **Date sync no longer wipes a date the first time it runs.** When a task had a due date on only one side (Logseq or the reminder) and date sync had not yet recorded a baseline, the next sync could read the empty side as a deliberate "date cleared" edit and erase the date from the populated side. The empty side is now seeded with the existing date instead. If both sides already hold *different* dates at first enable, Logseq wins.

### Changed
- The date 3-way merge decision is now a pure, unit-tested function (`Mapper.dateMergeAction`), mirroring the existing status merge. New `DateMergeTests` suite covers baseline seeding, steady-state, conflict, and two-pass regression guards in both wipe directions.

---

## Build 29 — 2026-05-29

### Changed
- `syncDates` now defaults to **true**. Due dates sync both ways for all new setups. Existing configs with `"syncDates": false` are unaffected.

---

## Build 28 — 2026-05-29

### Added
- **Configurable adopt destination.** When a reminder is created directly in a managed Reminders list, the resulting Logseq task now lands wherever you choose: at the **top level of today's journal page** (new default for fresh setups) or nested under a **named sub-block** such as "📥 Inbox". Configured interactively via `setup`.
- `setup` now prompts: *"Place newly-adopted tasks under a named sub-block on the journal page?"*. Pressing Enter on a re-run preserves your existing choice.
- EDN-injection guard: `"` and `\` in an inbox sub-block title are now escaped before Datascript interpolation.

### Changed
- `journalInboxTitle` in `config.json` is now optional. A missing key means top-level placement; a non-empty string means the named sub-block. Existing configs that store `"Inbox"` are unchanged until you re-run `setup`.

---

## Build 27 — 2026-05-23

### Changed
- Simplified cleanup: extracted `LaunchdAgent.guiDomain` helper.

## Build 26 and earlier

See git log.
