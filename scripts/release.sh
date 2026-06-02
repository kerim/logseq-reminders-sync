#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 1. Read build number from App.swift ──────────────────────────────────────
N=$(grep -E 'static let buildVersion\s*=\s*"[0-9]+"' Sources/logseq-reminders-sync/App.swift \
    | grep -oE '"[0-9]+"' | tr -d '"')

if [[ -z "$N" || ! "$N" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not parse buildVersion from App.swift" >&2
    exit 1
fi

TAG="build-$N"
echo "Build: $N  →  tag: $TAG"

# ── 2. Idempotency guard ──────────────────────────────────────────────────────
if gh release view "$TAG" --repo kerim/logseq-reminders-sync &>/dev/null; then
    echo "ERROR: release $TAG already exists. Bump buildVersion before releasing." >&2
    exit 1
fi

# ── 3. Extract CHANGELOG section for build N ─────────────────────────────────
# Anchored pattern prevents "## Build 3" matching "## Build 39".
NOTES=$(awk -v n="$N" '
    $0 ~ ("^## Build " n "([ \t—]|$)") { f=1; next }
    f && /^## Build /                   { exit }
    f && /^---$/                        { exit }
    f' CHANGELOG.md)

if [[ -z "$NOTES" ]]; then
    echo "ERROR: no CHANGELOG entry found for Build $N." >&2
    echo "       Add a '## Build $N' section to CHANGELOG.md before releasing." >&2
    exit 1
fi

echo ""
echo "Release notes:"
echo "──────────────────────────────────────"
echo "$NOTES"
echo "──────────────────────────────────────"
echo ""

# ── 4. Commit uncommitted changes if any ─────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Uncommitted changes:"
    git status --short
    echo ""
    read -r -p "Commit all changes as 'feat: build $N'? [Y/n] " yn
    yn="${yn:-Y}"
    if [[ "$yn" == [yY] ]]; then
        git add -A
        git commit -m "feat: build $N"
    else
        echo "Aborted. Commit your changes first, then re-run release.sh."
        exit 1
    fi
fi

# ── 5. Create the GitHub release ─────────────────────────────────────────────
URL=$(printf '%s\n' "$NOTES" \
    | gh release create "$TAG" \
        --repo kerim/logseq-reminders-sync \
        --title "Build $N" \
        --notes-file -)

echo "Released: $URL"
