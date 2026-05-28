#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash).
#
# Project rule (CLAUDE.md): bump App.buildVersion before every build, never
# reuse a number. This does NOT block the build — it just warns when a
# `swift build` is about to run while App.buildVersion still matches the
# value committed at HEAD (i.e. it wasn't bumped). Warning is surfaced to the
# user (systemMessage) and injected into Claude's context (additionalContext)
# so the version gets bumped.
#
# Reads the PreToolUse JSON event on stdin. Always allows the tool call.
set -euo pipefail

JQ=/usr/bin/jq
payload="$(cat)"

command_str="$("$JQ" -r '.tool_input.command // empty' <<<"$payload")"

# Only react to swift build invocations.
if ! grep -Eq 'swift[[:space:]]+build' <<<"$command_str"; then
    exit 0
fi

cwd="$("$JQ" -r '.cwd // empty' <<<"$payload")"
[[ -n "$cwd" ]] && cd "$cwd" 2>/dev/null || true

app_file="Sources/logseq-reminders-sync/App.swift"
[[ -f "$app_file" ]] || exit 0   # not this project's layout; stay silent

extract='s/.*buildVersion[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p'
current="$(grep -E 'buildVersion[[:space:]]*=' "$app_file" | sed -nE "$extract" | head -1)"
committed="$(git show HEAD:"$app_file" 2>/dev/null | grep -E 'buildVersion[[:space:]]*=' | sed -nE "$extract" | head -1)"

# Warn only when we can read both and they're identical (not bumped).
if [[ -n "$current" && -n "$committed" && "$current" == "$committed" ]]; then
    msg="App.buildVersion is still \"$current\" (unchanged since last commit). CLAUDE.md requires bumping the build number before every build — increment it before installing."
    "$JQ" -n --arg m "$msg" '{
        systemMessage: ("⚠️  " + $m),
        hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext: $m }
    }'
fi

exit 0
