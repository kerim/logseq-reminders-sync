#!/usr/bin/env bash
# One-shot bootstrap for a fresh clone: create the signing certificate, build the
# release binary, sign it, and install to ~/.local/bin/. Run once after cloning.
#   bash scripts/install.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
cd "$ROOT"

echo "==> Checking for the logseq CLI…"
if command -v logseq >/dev/null 2>&1; then
    echo "    Found: $(command -v logseq)"
else
    echo "    WARNING: 'logseq' CLI not found on PATH."
    echo "    Install it first, or point the tool at it later via the"
    echo "    \"logseqCliPath\" field in ~/.logseq-reminders-sync/config.json."
fi

echo "==> Creating code-signing certificate (one-time; may prompt for your login password)…"
bash "$SCRIPT_DIR/create-signing-cert.sh"

echo "==> Building release…"
swift build -c release

echo "==> Signing and installing…"
bash "$SCRIPT_DIR/sign.sh" release

echo ""
echo "Installed to ~/.local/bin/logseq-reminders-sync"
echo "Ensure ~/.local/bin is on your PATH, then run:"
echo "    logseq-reminders-sync setup"
