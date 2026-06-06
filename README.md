# logseq-reminders-sync

**A macOS command-line tool that syncs [Logseq](https://logseq.com) tasks with Apple Reminders.** 

- It offers true two-way sync, but **only for metadata**: *completion*, *status markers*, *priority*, and *due dates*. 

- Every Reminder has a URL that will open the original Logseq task block in the Desktop or iOS app.

- The title and notes fields are only **synced in one direction**. Logseq remains the *sole source of truth*, and *markdown is stripped* on importing to Reminders. (Tasks can only be deleted in Logseq.) The only exception is when you **create new tasks** in Reminders (and those get "owned" by Logseq after they are synced). 
- It also offers **one-way note capture**: a dedicated *Logseq Notes* list imports reminders into Logseq as plain notes (not tasks). See [Capturing notes](#capturing-notes-one-way).
- It runs on a schedule that you setup on install. You can also invoke a manual sync.

> Requires **macOS 14 (Sonoma) or later** and the **`logseq` CLI** (v2, only available with the new DB version of Logseq)

---

### What syncs?

Only tasks with a priority of **Urgent, High, or Medium** sync. A task with no priority (or `Low`) is ignored. Priority is effectively the on/off switch: give a task one of those three priorities and it appears in Reminders; lower it to `Low` or none, and its reminder is removed again.

### Each status marker has its own list

There are five **status** lists, one for each Logseq status — plus a sixth **Logseq Notes** list for one-way note capture, described in [Capturing notes](#capturing-notes-one-way) below.

| Logseq status | Reminders list |
| --- | --- | 
| Backlog | **Logseq Backlog** | 
| Todo | **Logseq Todo** | 
| Doing | **Logseq Doing** | 
| In Review | **Logseq In Review** | 
| Canceled | **Logseq Canceled** (Only for canceling previously synced tasks.) | 
| Done | (Handled by Reminders completion status) | 

A task's status *is* the list it lives in, so **moving a reminder to a different list changes the task's status in Logseq** — drag a reminder from *Logseq Todo* to *Logseq Doing* and the task becomes Doing. The reverse holds too: change the status in Logseq and the reminder moves to the matching list.

There's no list for **Done**. Completing a reminder (checking it off) marks the task Done in Logseq; un-checking it restores whatever open status it had before.

**Canceled** only exists to cancel tasks that were already synced. Existing cancelled tasks from logseq are ignored on sync. You can cancel a task by moving it to the **Canceled** list. 

### Due dates (Scheduled / Deadline)

Logseq **Deadline** date takes precedence over **Scheduled** when both are set. Whichever field is present maps to the reminder's due date in Reminders, and vice versa — a due date set or changed in Reminders writes back to the same field in Logseq. If a task has no date on either side, dates are left alone.

Conflict resolution for dates follows the same rule as everything else: if both sides changed since the last sync, the most recently edited one wins.

This feature can be turned off. Disable it by setting `"syncDates":false` in `~/.logseq-reminders-sync/config.json`.

### When both sides changed

If a task and its reminder were both edited since the last sync, the **most recent edit wins**. Exact ties favor Logseq.

### The link is durable

Each Logseq task stores a hidden `reminder-id` property pointing at its reminder. That link lives in your graph — not in a throwaway cache — so even if the tool's local state file is deleted, it re-discovers every pairing on the next run and never creates duplicates.

You can set the `reminder-id` property to "hide by default" so you don't see it in your graph.

### Capturing notes (one-way)

A sixth list, **Logseq Notes**, is for quick capture — not tasks. Anything you add there is imported into Logseq once, then checked off in Reminders:

- The reminder's **title** becomes a top-level block on today's journal (in the same place new tasks land — see `journalInboxTitle`).
- Each **paragraph** of the reminder's note becomes a nested block beneath it (blank lines are dropped).
- It's a plain note — **no task status** is assigned.
- After import, the reminder is **marked complete** so it's never imported twice.

This is strictly **one-way**: notes are never synced back, and **deleting the reminder afterwards leaves the Logseq note untouched** (unlike a task, whose reminder would reappear on the next sync). Notes are anchored by a separate hidden `captured-reminder-id` property — distinct from the two-way `reminder-id` link above — which is what keeps them import-only and delete-safe.

To get the list, re-run `setup` — it creates **Logseq Notes** alongside the five status lists.

---

## Install

```fish
git clone https://github.com/kerim/logseq-reminders-sync
cd logseq-reminders-sync
bash scripts/install.sh
```

`install.sh` creates a one-time code-signing certificate (it may ask for your login password), builds the release binary, signs it, and installs it to `~/.local/bin/logseq-reminders-sync`. Make sure `~/.local/bin` is on your `PATH`.

**Why code signing?** macOS gates Reminders access by code-signing identity. The tool signs itself with a stable self-signed certificate so it gets one persistent Reminders permission grant instead of re-prompting every build. **Back up that certificate** (or your login keychain) — losing it means re-granting Reminders access.

---

## First run

```fish
logseq-reminders-sync setup
```

Setup walks you through everything:

1. Requests Reminders access (approve the macOS prompt).
2. Lets you pick which Logseq graph to sync.
3. Creates the five status lists plus a **Logseq Notes** list (one-way note capture).
4. Asks where newly-adopted reminders should land: **top level of today's journal** (default) or **under a named sub-block** (e.g. `📥 Inbox`).
5. Writes the config file.
6. Optionally installs a background agent that syncs automatically on a schedule (default: every 15 minutes).

That's it — once setup finishes, prioritized tasks start appearing in Reminders on the next sync.

---

## Everyday use

If you installed the background agent, **you don't need to do anything** — it syncs on its schedule. 

To run a sync by hand:

```fish
logseq-reminders-sync --once      # one sync pass (this is also the default with no args)
logseq-reminders-sync --force     # one pass, skipping the "did anything change?" gate
```

### Update notifications

Once a day, the sync quietly checks whether a newer release exists on GitHub. If one does, you get a macOS notification banner: "Build 41 is available (you have 40)." The check is throttled — it runs at most once every 24 hours and only nags you once per new version. It silently steps aside if the network is unavailable, so it never slows down or breaks a sync pass.

To check immediately (bypasses the throttle):

```fish
logseq-reminders-sync --check-update
```

The notification is shown via `osascript`, so macOS attributes the banner to "Script Editor" rather than to the tool — that's expected. If Do Not Disturb or Focus is active, the banner may be suppressed; the log entry in `~/.logseq-reminders-sync/log/` still records that a newer build was found.

### Updating to the latest version

Updating is the same as installing: you grab a fresh copy of the code and run the installer again. You **don't** need to find the folder you originally downloaded — the steps below download a clean copy, so they work even if you've forgotten where it went or never used the command line before.

1. Open the **Terminal** app.
2. Copy the block below, paste it into the Terminal window, and press Return. It runs as several steps; let it finish — it may ask for your Mac login password partway through, which is normal.

```fish
cd ~
rm -rf logseq-reminders-sync-update
git clone https://github.com/kerim/logseq-reminders-sync logseq-reminders-sync-update
cd logseq-reminders-sync-update
bash scripts/install.sh
```

What each line does, in plain terms: go to your home folder → throw away any leftover download from a previous update → download the newest code into a folder named `logseq-reminders-sync-update` → step into that folder → run the installer.

`install.sh` doubles as the updater: it reuses your existing signing certificate, rebuilds the app, and replaces the installed copy at `~/.local/bin/`. **Nothing you care about is touched** — your settings, the background sync schedule, the Reminders lists, and the markers in your Logseq graph all stay exactly as they were. Only the program itself is swapped for the new version.

When it's done, check that the new version is in place:

```fish
logseq-reminders-sync --version
```

The build number it prints should match the latest one announced in the update banner. Because the new copy is signed with the same certificate as before, macOS keeps your existing Reminders permission — you won't be asked to grant access again. (The one exception is if you've lost or recreated that certificate; see [Install](#install).)

## Switching graphs

To point the tool at a different Logseq graph:

```fish
logseq-reminders-sync switch-graph
```

This does a **full clean**: it empties the managed lists (the five status lists and **Logseq Notes**), removes the sync markers from the old graph, resets the sync state, and switches to the graph you pick. After confirming, the next sync populates the lists from the new graph. The command is careful — it validates and confirms *before* deleting anything, and won't switch if it can't fully empty the lists.

---

## Stopping & uninstalling

### Pause automatic syncing

```fish
logseq-reminders-sync pause
```

Durably stops the background agent — survives logout and reboot. Your config, lists, and graph markers are untouched, and you can still run a sync by hand.

```fish
logseq-reminders-sync resume   # re-enable and restart the agent
```

### Uninstall completely

```fish
logseq-reminders-sync uninstall
```

Type `uninstall` at the confirmation prompt. The command:

- Stops and removes the background agent
- Deletes the six managed Reminders lists (and all reminders in them)
- Strips the `reminder-id` / `captured-reminder-id` markers from your Logseq graph
- Removes all local files under `~/.logseq-reminders-sync/`
- Removes the installed binary at `~/.local/bin/logseq-reminders-sync`
- Removes the signing certificate from your login keychain

One step it can't do automatically: **revoke the Reminders permission**. Do it in **System Settings → Privacy & Security → Reminders**.

Optionally delete the cloned source directory:

```fish
rm -rf /path/to/logseq-reminders-sync
```

### Manual fallback

If the binary is gone or `uninstall` can't finish, here are the individual steps:

```fish
# Durable pause (survives reboot):
launchctl disable gui/(id -u)/com.kerim.logseq-reminders-sync
launchctl bootout gui/(id -u)/com.kerim.logseq-reminders-sync

# Re-enable after a durable pause:
launchctl enable gui/(id -u)/com.kerim.logseq-reminders-sync
launchctl bootstrap gui/(id -u) ~/Library/LaunchAgents/com.kerim.logseq-reminders-sync.plist

# Session-only stop (does NOT survive reboot — use durable pause above for permanence):
launchctl bootout gui/(id -u)/com.kerim.logseq-reminders-sync

# Remove agent plist, binary, config dir, and signing certificate:
rm ~/Library/LaunchAgents/com.kerim.logseq-reminders-sync.plist
rm ~/.local/bin/logseq-reminders-sync
rm -rf ~/.logseq-reminders-sync
security delete-identity -c "logseq-reminders-sync" ~/Library/Keychains/login.keychain-db
```

---

## Configuration

Config lives at `~/.logseq-reminders-sync/config.json` (created by `setup`). Fields:

| Field | Meaning |
|-------|---------|
| `graph` | The Logseq graph name to sync. |
| `statusLists` | Map of status → `{id, title}` for each of the 5 status lists. Keys are canonical statuses (`Backlog`, `Todo`, `Doing`, `In Review`, `Canceled`). The sixth **Logseq Notes** list is configured separately via `notesList` (below). |
| `journalInboxTitle` | Where newly-adopted reminders land on today's journal page. Omit (or set to `null`) to place tasks at the **top level** of the journal; set to a block title (e.g. `"📥 Inbox"`) to nest them under that sub-block. Configured via `setup`. |
| `notesList` | The **Logseq Notes** list (`{id, title}`) used for one-way note capture. Created by `setup`. Absent in configs predating this feature — when absent, note capture is simply inactive. |
| `conflictPolicy` | Conflict resolution strategy (`mostRecentWins`). |
| `syncDates` | Sync due dates both ways. Default `true`. |
| `syncPriority` | Sync task priority both ways. Default `true`. |
| `gateForceFullRunMinutes` | Force a full sync at least this often, regardless of detected changes. Default `60`. |
| `logseqCliPath` | Absolute path to the `logseq` CLI. Set by `setup`; needed because the scheduled background run has a minimal environment and can't search your `PATH`. |

Runtime files (all under `~/.logseq-reminders-sync/`): `state.json` (rebuildable cache), `log/YYYY-MM-DD.log` (daily logs), `lock` (run lock).

---

## Troubleshooting

Read-only diagnostics that don't change anything:

```fish
logseq-reminders-sync --dump-reminders   # list all Reminders lists + recent reminders
logseq-reminders-sync --dump-tasks       # list prioritized tasks in the configured graph
```

One maintenance command that does write:

```fish
logseq-reminders-sync --backfill-links   # add the Logseq backlink to older mirror reminders' URL field
```

- **"Reminders access denied":** approve access in System Settings → Privacy & Security → Reminders, then re-run `setup`.
- **"Could not find the logseq CLI":** install it, put it on your `PATH`, or set `logseqCliPath` in the config to its absolute path.
- **Background sync isn't running:** check `launchctl list | grep logseq` and the agent logs at `~/.logseq-reminders-sync/log/launchd.err.log`.

The background agent is a LaunchAgent labeled `com.kerim.logseq-reminders-sync` (the identifier is arbitrary but kept stable so the Reminders grant sticks). To pause or remove it, see [Stopping & uninstalling](#stopping--uninstalling).

---

## Development

```fish
swift build                 # debug build
swift test                  # run the test suite
bash scripts/sign.sh        # sign + install the debug binary
bash scripts/sign.sh release
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the architecture and internals.

## License

[MIT](LICENSE) © P. Kerim Friedman
