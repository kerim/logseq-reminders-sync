---
name: build-sign-install
description: Build, code-sign, and install the logseq-reminders-sync CLI in one ritual — bumps the build number first, then builds, signs, installs to ~/.local/bin, and verifies. Use when the user wants to build and install the tool. Invoke with "release" to build the release configuration (default is debug).
disable-model-invocation: true
---

# build-sign-install

The full install ritual for logseq-reminders-sync. Code signing is **not optional** here: the binary calls `EKEventStore.requestFullAccessToReminders()`, which is TCC-gated by signing identity. A built-but-unsigned binary (or a build with a stale version) silently re-triggers the Reminders permission prompt and behaves like a different app. This skill makes sure the build number bumps, the binary gets signed with the project identity, and the install actually lands — so none of those steps get skipped.

Configuration: `debug` (default) or `release` — taken from the argument the user passed when invoking the skill.

## Steps — do these in order, stop on any failure

1. **Bump the build number.** Read `Sources/logseq-reminders-sync/App.swift`, find `static let buildVersion = "<N>"`, and increment `<N>` by 1 (it is a plain integer string). Never reuse a number, even after a failed attempt. Edit the file to the new value and tell the user the old → new number.

2. **Build.**
   - debug: `swift build`
   - release: `swift build -c release`
   If the build fails, stop and report the compiler errors — do not sign or install a stale binary.

3. **Sign + install.** Run `bash scripts/sign.sh <config>` (`bash scripts/sign.sh` for debug, `bash scripts/sign.sh release` for release). This codesigns `.build/<config>/logseq-reminders-sync` with the `logseq-reminders-sync` identity and copies it to `~/.local/bin/logseq-reminders-sync`. If signing fails because the identity is missing, point the user at `scripts/create-signing-cert.sh` (re-creating the cert means re-granting Reminders access) — do not work around it.

4. **Verify the install.** Run `~/.local/bin/logseq-reminders-sync --version` and confirm it prints the **new** build number you set in step 1. If it prints the old number, the install didn't take — investigate before claiming success.

5. **Report and hand off.** State the configuration built, the new build number, and that `--version` confirmed it. Then ask the user to run a real sync (or `--dump-tasks` / `--dump-reminders`) to confirm Reminders access still works — do not mark the task complete until the user verifies.

## Notes

- Pure Swift Package Manager project — never invoke `xcodebuild` or XcodeBuild MCP tools here.
- If the user only wants to compile-check (not install), that's a plain `swift build`, not this skill — this skill always bumps the version and installs.
- The `swift build` step will trip the build-version reminder hook; that's fine — you've already bumped, so the warning won't fire.
