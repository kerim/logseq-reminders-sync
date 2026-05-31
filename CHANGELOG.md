# Changelog

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
