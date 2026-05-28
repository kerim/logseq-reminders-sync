#!/usr/bin/env bash
# Creates a stable self-signed code-signing identity for logseq-reminders-sync.
# Run once. macOS will prompt for your login password to set trust.
set -e

CERT_NAME="logseq-reminders-sync"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Already exists?
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
    echo "Certificate '$CERT_NAME' already exists and is trusted for code signing."
    security find-identity -v -p codesigning "$KEYCHAIN" | grep "$CERT_NAME"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Creating self-signed code-signing certificate '$CERT_NAME' (10-year validity)..."

cat > "$TMP/codesign.cnf" << EOF
[req]
default_bits       = 2048
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_codesign
prompt             = no

[dn]
CN = $CERT_NAME

[v3_codesign]
subjectKeyIdentifier   = hash
basicConstraints       = critical,CA:FALSE
extendedKeyUsage       = codeSigning
keyUsage               = critical,digitalSignature
EOF

openssl req -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" \
    -x509 -days 3650 \
    -out   "$TMP/cert.pem" \
    -config "$TMP/codesign.cnf" 2>/dev/null

TMPPASS=$(openssl rand -hex 16)
openssl pkcs12 -legacy -export \
    -out     "$TMP/cert.p12" \
    -inkey   "$TMP/key.pem" \
    -in      "$TMP/cert.pem" \
    -passout "pass:$TMPPASS" 2>/dev/null

echo "Importing into login keychain..."
security import "$TMP/cert.p12" \
    -k "$KEYCHAIN" \
    -P "$TMPPASS" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

echo "Setting code-signing trust (you may be prompted for your login password)..."
security add-trusted-cert \
    -r trustRoot \
    -k "$KEYCHAIN" \
    "$TMP/cert.pem"

echo ""
echo "Done. Verifying..."
security find-identity -v -p codesigning "$KEYCHAIN" | grep "$CERT_NAME" \
    || { echo "ERROR: cert not found in codesigning identities — trust may not have applied."; exit 1; }

echo ""
echo "SUCCESS. Certificate '$CERT_NAME' is ready for code signing."
echo "IMPORTANT: Back up your keychain or export this cert — losing it means re-creating"
echo "           the identity and re-granting Reminders access."
