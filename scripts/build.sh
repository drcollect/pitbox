#!/bin/bash
# Build and sign build/Pitbox.app with SwiftPM and a hand-assembled bundle (Command Line Tools are enough; no Xcode).
#
#   scripts/build.sh
#
# Environment (all optional):
#   PITBOX_SIGN_IDENTITY  the code-signing identity to use. Default: "Pitbox Dev" when scripts/make-dev-cert.sh has
#                         created it, else an ad hoc signature (see the warning below).
#   PITBOX_BUNDLE_ID      the bundle identifier. Default: io.github.drcollect.pitbox
#   PITBOX_SCRATCH        SwiftPM's build folder (passed as --scratch-path) instead of .build
#
# What it does: builds the app (product Pitbox) and the command helper (product pitbox-command-helper) in release mode,
# puts both into build/Pitbox.app/Contents/MacOS, writes Info.plist, signs the helper first and then the app (so the
# app's signature covers the signed helper), and checks the result with `codesign --verify --deep --strict`.
# It does not open, install or register the app. Move it to ~/Applications yourself and open it there.
#
# The helper matters: command tabs start only through Contents/MacOS/pitbox-command-helper beside the app's own
# executable (the app checks it before every command: a regular file, yours or root's, not writable by others).
# Without it, Run and Type are off.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUNDLE_ID="${PITBOX_BUNDLE_ID:-io.github.drcollect.pitbox}"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo "ERROR: PITBOX_BUNDLE_ID must look like io.github.example.pitbox (letters, digits, - and dots)" >&2
  exit 1
fi
VERSION="0.1.0"
if [[ -f "$ROOT/VERSION" ]]; then
  VERSION="$(head -n 1 "$ROOT/VERSION" | tr -d '[:space:]')"
  if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "ERROR: VERSION must hold a version like 1.2.3 on its first line" >&2
    exit 1
  fi
fi

# Signing identity: $PITBOX_SIGN_IDENTITY, else "Pitbox Dev" if scripts/make-dev-cert.sh created it, else ad hoc ("-").
if [[ -n "${PITBOX_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$PITBOX_SIGN_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | /usr/bin/grep -q '"Pitbox Dev"'; then
  IDENTITY="Pitbox Dev"
else
  IDENTITY="-"
fi

SCRATCH=()
if [[ -n "${PITBOX_SCRATCH:-}" ]]; then SCRATCH=(--scratch-path "$PITBOX_SCRATCH"); fi

echo "==> swift build Pitbox (release)"
swift build -c release ${SCRATCH[@]+"${SCRATCH[@]}"} --product Pitbox
echo "==> swift build pitbox-command-helper (release)"
swift build -c release ${SCRATCH[@]+"${SCRATCH[@]}"} --product pitbox-command-helper
BIN="$(swift build -c release ${SCRATCH[@]+"${SCRATCH[@]}"} --show-bin-path)"
for product in Pitbox pitbox-command-helper; do
  [[ -f "$BIN/$product" ]] || { echo "ERROR: $BIN/$product was not built" >&2; exit 1; }
done

OUT="$ROOT/build"
APP="$OUT/Pitbox.app"
echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Pitbox" "$APP/Contents/MacOS/Pitbox"
cp "$BIN/pitbox-command-helper" "$APP/Contents/MacOS/pitbox-command-helper"
chmod 755 "$APP/Contents/MacOS/Pitbox" "$APP/Contents/MacOS/pitbox-command-helper"
# No usage strings: Pitbox uses no microphone, calendar, location or automation (Apple Events), so macOS never asks for
# them in its name. LSUIElement: no Dock icon and no app menu; Pitbox lives in its block and its menu bar item.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Pitbox</string>
  <key>CFBundleDisplayName</key><string>Pitbox</string>
  <key>CFBundleExecutable</key><string>Pitbox</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# Sign the helper first, then the app: the app's signature seals the signed helper inside it.
if [[ "$IDENTITY" == "-" ]]; then
  echo "WARNING: this build is signed ad hoc (no 'Pitbox Dev' identity was found, or PITBOX_SIGN_IDENTITY is \"-\")."
  echo "         macOS ties the Accessibility permission to the signature, and an ad hoc signature changes with every"
  echo "         build: you will have to grant Accessibility again after each rebuild. To keep the grant, run"
  echo "         scripts/make-dev-cert.sh once; build.sh then signs with the 'Pitbox Dev' identity by itself."
fi
echo "==> sign with ${IDENTITY/#-/an ad hoc signature}"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID.command-helper" "$APP/Contents/MacOS/pitbox-command-helper"
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"

echo "==> check $APP"
codesign --verify --deep --strict "$APP" || { echo "ERROR: the signature of $APP does not verify (--strict)" >&2; exit 1; }
echo "==> built $APP"
