#!/usr/bin/env bash
# Sign the debug or release binary after each swift build.
# Usage: ./scripts/sign.sh [debug|release]   (default: debug)
set -e

CERT_NAME="logseq-reminders-sync"
CONFIG="${1:-debug}"
BINARY=".build/$CONFIG/logseq-reminders-sync"
INSTALL_PATH="$HOME/.local/bin/logseq-reminders-sync"

if [[ ! -f "$BINARY" ]]; then
    echo "Binary not found: $BINARY"
    echo "Run 'swift build' first."
    exit 1
fi

echo "Signing $BINARY with identity '$CERT_NAME'..."
codesign --force --sign "$CERT_NAME" \
    --identifier "com.kerim.logseq-reminders-sync" \
    "$BINARY"

echo "Verifying signature..."
codesign --verify --verbose "$BINARY"

echo "Installing to $INSTALL_PATH..."
mkdir -p "$(dirname "$INSTALL_PATH")"
cp "$BINARY" "$INSTALL_PATH"

echo "Done. Run: $INSTALL_PATH --version"
