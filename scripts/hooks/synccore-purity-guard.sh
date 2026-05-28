#!/usr/bin/env bash
# PreToolUse hook (matcher: Edit|Write).
#
# Enforces the architectural invariant documented in CLAUDE.md: the SyncCore
# target must stay free of EventKit / AppKit / Cocoa and of Process, so it
# remains unit-testable without a host environment. If an edit would introduce
# one of those into a Sources/SyncCore/*.swift file, this blocks the write
# (exit 2) and tells Claude why. Foundation is allowed (Date, Codable, etc.).
#
# Reads the PreToolUse JSON event on stdin. Inspects only the text being
# written (Write -> .tool_input.content, Edit -> .tool_input.new_string), so
# it fires exactly when a forbidden import is being added.
set -euo pipefail

JQ=/usr/bin/jq
payload="$(cat)"

file_path="$("$JQ" -r '.tool_input.file_path // empty' <<<"$payload")"

# Only police Swift files inside the SyncCore target.
case "$file_path" in
    */Sources/SyncCore/*.swift|Sources/SyncCore/*.swift) ;;
    *) exit 0 ;;
esac

# Text being introduced by this write (full file for Write, the new side for Edit).
new_text="$("$JQ" -r '.tool_input.content // .tool_input.new_string // empty' <<<"$payload")"

violations=""
if grep -Eq '^[[:space:]]*import[[:space:]]+(EventKit|AppKit|Cocoa|IOKit)\b' <<<"$new_text"; then
    bad="$(grep -Eo 'import[[:space:]]+(EventKit|AppKit|Cocoa|IOKit)' <<<"$new_text" | sort -u | tr '\n' ' ')"
    violations="forbidden import(s): ${bad}"
fi
if grep -Eq '\bProcess[[:space:]]*\(' <<<"$new_text"; then
    violations="${violations}${violations:+; }use of Process(...)"
fi

if [[ -n "$violations" ]]; then
    echo "SyncCore purity guard: $file_path may not contain $violations." >&2
    echo "SyncCore must stay free of EventKit/AppKit/Cocoa and Process so it" >&2
    echo "stays unit-testable (see CLAUDE.md). Put host-only code in the" >&2
    echo "logseq-reminders-sync executable target instead." >&2
    exit 2
fi

exit 0
