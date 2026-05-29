# Changelog

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
