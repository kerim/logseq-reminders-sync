# logseq-reminders-sync

A macOS command-line tool that **bi-directionally syncs your prioritized [Logseq](https://logseq.com) DB-graph tasks with Apple Reminders.** Each prioritized task (Urgent / High / Medium) becomes a reminder, and its Logseq status maps to one of five Reminders lists. Edit on either side — title, status, due date, priority, completion — and the change flows back to the other.

It runs one sync pass per invocation and exits (no daemon), so it's meant to be triggered on a schedule. `setup` installs that schedule for you.

> Requires **macOS 14 (Sonoma) or later** and the **`logseq` CLI**.

---

## How it works (in brief)

- **Five lists, one per status.** Your open tasks live in lists named *Logseq Backlog / Todo / Doing / In Review*, and closed ones in *Logseq Canceled*. Moving a reminder between these lists changes the task's status in Logseq, and vice-versa.
- **Two directions.**
  - *Logseq → Reminders:* any task with priority Urgent/High/Medium and an open status gets a reminder in the matching list. Drop a task's priority to Low/none and its reminder is removed.
  - *Reminders → Logseq:* a reminder you create directly in one of the five lists is "adopted" — a matching task is created under today's journal inbox.
- **Conflicts resolve most-recent-wins.** Whichever side changed last takes precedence; ties favor Logseq.
- **The link is stored in Logseq.** Each task carries a hidden `reminder-id` property tying it to its reminder, so the pairing survives even if the local state cache is deleted.

---

## Install

```fish
git clone <repo-url>
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
3. Creates the five Reminders lists.
4. Writes the config file.
5. Optionally installs a background agent that syncs automatically on a schedule (default: every 15 minutes).

That's it — once setup finishes, prioritized tasks start appearing in Reminders on the next sync.

---

## Everyday use

If you installed the background agent, you don't need to do anything — it syncs on its schedule. To run a sync by hand:

```fish
logseq-reminders-sync --once      # one sync pass (this is also the default with no args)
logseq-reminders-sync --force     # one pass, skipping the "did anything change?" gate
```

## Switching graphs

To point the tool at a different Logseq graph:

```fish
logseq-reminders-sync switch-graph
```

This does a **full clean**: it empties the five Reminders lists, removes the sync markers from the old graph, resets the sync state, and switches to the graph you pick. After confirming, the next sync populates the lists from the new graph. The command is careful — it validates and confirms *before* deleting anything, and won't switch if it can't fully empty the lists.

---

## Configuration

Config lives at `~/.logseq-reminders-sync/config.json` (created by `setup`). Fields:

| Field | Meaning |
|-------|---------|
| `graph` | The Logseq graph name to sync. |
| `statusLists` | Map of status → `{id, title}` for each of the 5 lists. Keys are canonical statuses (`Backlog`, `Todo`, `Doing`, `In Review`, `Canceled`). |
| `journalInboxTitle` | Title of the inbox block on journal pages where adopted reminders land. |
| `fallbackInboxPage` | Page used if the journal inbox isn't available. |
| `conflictPolicy` | Conflict resolution strategy (`mostRecentWins`). |
| `syncDates` | Sync due dates both ways. Default `false`. |
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

The background agent is a LaunchAgent labeled `com.kerim.logseq-reminders-sync` (the identifier is arbitrary but kept stable so the Reminders grant sticks). To remove it:

```fish
launchctl bootout gui/(id -u)/com.kerim.logseq-reminders-sync
rm ~/Library/LaunchAgents/com.kerim.logseq-reminders-sync.plist
```

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
