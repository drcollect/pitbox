#!/bin/bash
# One-time setup on your Mac: creates a local, self-signed code-signing identity called "Pitbox Dev", so the Pitbox you
# build yourself keeps its Accessibility permission across rebuilds.
#
# Why: macOS ties the Accessibility permission to the app's code signature. Without an identity, scripts/build.sh signs
# ad hoc, that signature changes with every build, and macOS forgets the permission after each rebuild. A stable
# identity keeps it.
#
# What it does, plainly:
#   1. Makes a new private key and a self-signed certificate for it (valid 10 years), usable for code signing only.
#   2. Imports both into your login keychain. Only /usr/bin/codesign may use the key without asking.
#   3. Marks the certificate as trusted for code signing on this Mac (`security add-trusted-cert -r trustRoot -p codeSign`).
#      macOS asks for your login password for this step.
# What that means: anyone who holds this key could sign code that this Mac trusts for code signing. The key is created
# on this Mac, goes straight into your login keychain and never leaves it; nothing is sent anywhere.
# The first time codesign uses the key, macOS may ask "codesign wants to use key": click "Always Allow".
#
# To remove it again (the certificate and its key):
#   security delete-identity -c "Pitbox Dev"
# or delete the "Pitbox Dev" certificate and its key in Keychain Access. scripts/build.sh then signs ad hoc again.
#
#   scripts/make-dev-cert.sh [identity-name]     (default name: Pitbox Dev)
#   afterwards scripts/build.sh signs with it by itself (override with PITBOX_SIGN_IDENTITY).
#
# Environment (for testing the script): PITBOX_KEYCHAIN=<keychain file> (default: your login keychain),
# PITBOX_SKIP_TRUST=1 (do not change trust settings).
set -euo pipefail
NAME="${1:-Pitbox Dev}"
KEYCHAIN="${PITBOX_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
if [[ -z "$NAME" || "$NAME" == *[\"\\/]* || "$NAME" == *$'\n'* ]]; then
  echo "The identity name must not be empty or contain \", \\, / or a line break." >&2
  exit 1
fi

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -qF "\"$NAME\""; then
  echo "The identity '$NAME' already exists in $KEYCHAIN and is valid for code signing: nothing to do."
  exit 0
fi
# Created by an earlier run whose trust step was skipped or declined: repeat only the trust step.
EXISTING=0
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -qF "\"$NAME\""; then
  EXISTING=1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
chmod 700 "$TMP"
PASS="$(uuidgen)"
cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

if [[ "$EXISTING" == "1" ]]; then
  echo "The identity '$NAME' exists in $KEYCHAIN but is not trusted for code signing yet; repeating only that step..."
  # Pick the certificate by the identity's own SHA-1 (an exact name match), never by a substring of the name.
  HASHES="$(security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null \
    | /usr/bin/awk -v n="\"$NAME\"" 'index($0, n) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{40}$/) print $i }' \
    | /usr/bin/sort -u)"
  COUNT="$(printf '%s\n' "$HASHES" | /usr/bin/grep -c . || true)"
  if [[ "$COUNT" != "1" ]]; then
    echo "Found $COUNT identities named exactly '$NAME' in $KEYCHAIN; expected one. Remove the extra ones in Keychain" >&2
    echo "Access (or: security delete-identity -Z <hash>), then run this script again. Hashes:" >&2
    printf '  %s\n' $HASHES >&2
    exit 1
  fi
  security find-certificate -a -Z -p "$KEYCHAIN" | /usr/bin/awk -v h="$HASHES" '
    /^SHA-1 hash: / { current = $3; next }
    current == h && /-----BEGIN CERTIFICATE-----/ { printing = 1 }
    printing { print }
    printing && /-----END CERTIFICATE-----/ { exit }' > "$TMP/cert.pem"
  if [[ ! -s "$TMP/cert.pem" ]]; then
    echo "Could not read the certificate of '$NAME' (SHA-1 $HASHES) from $KEYCHAIN." >&2
    exit 1
  fi
else
echo "Creating a key and a self-signed code-signing certificate named '$NAME'..."
# macOS's own LibreSSL writes a PKCS#12 file that `security import` accepts (OpenSSL 3 would need -legacy).
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
  -config "$TMP/openssl.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null
echo "Importing it into $KEYCHAIN (only codesign may use the key)..."
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null
fi

if [[ "${PITBOX_SKIP_TRUST:-0}" != "1" ]]; then
  echo "Marking the certificate as trusted for code signing on this Mac (macOS asks for your login password)..."
  if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
    echo "The trust step was cancelled or failed." >&2
  fi
fi

# codesign only uses identities whose certificate is trusted for code signing: check that the trust step worked.
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | /usr/bin/grep -qF "\"$NAME\""; then
  echo "Created the code-signing identity '$NAME' in $KEYCHAIN."
  echo "scripts/build.sh now signs with it by itself. To remove it: security delete-identity -c \"$NAME\""
else
  echo "Created '$NAME' in $KEYCHAIN, but it is not a valid signing identity yet (the trust step was skipped or declined)." >&2
  echo "Run this script again, or in Keychain Access set the certificate's Code Signing trust to Always Trust." >&2
  echo "To remove it: security delete-identity -c \"$NAME\"" >&2
  exit 1
fi
