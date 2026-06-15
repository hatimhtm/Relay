#!/bin/bash
# Build, Developer-ID-sign, notarize and staple Relay into a distributable .app
# (+ .zip) that runs warning-free on any Mac.
#
# Prerequisites (one-time — see RELEASE.md):
#   1. A "Developer ID Application" certificate in your keychain.
#   2. Notary credentials stored as a keychain profile named "relay-notary":
#        xcrun notarytool store-credentials relay-notary \
#          --apple-id "<your-apple-id>" --team-id ULHJAB7ZT3 --password "<app-specific-password>"
#
# Usage:  scripts/release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DEV="/Applications/Xcode.app/Contents/Developer"
ENT="$ROOT/RelayNative/RelayNative.entitlements"
TEAM="ULHJAB7ZT3"
NOTARY_PROFILE="relay-notary"
DIST="$ROOT/dist"

# --- preflight ---------------------------------------------------------------
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | grep "$TEAM" | head -1 | awk '{print $2}')
if [ -z "${IDENTITY:-}" ]; then
  cat >&2 <<EOF
error: no "Developer ID Application" certificate for team $TEAM found.

Create one first (see RELEASE.md):
  Xcode → Settings → Accounts → (select your team) → Manage Certificates →
  + → "Developer ID Application".  Then re-run this script.
EOF
  exit 1
fi
echo "Developer ID identity: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: notary credentials profile "$NOTARY_PROFILE" not found.

Store them once (needs an app-specific password from appleid.apple.com):
  xcrun notarytool store-credentials $NOTARY_PROFILE \\
    --apple-id "<your-apple-id-email>" --team-id $TEAM --password "<app-specific-password>"
EOF
  exit 1
fi

# --- build (unsigned) --------------------------------------------------------
echo "→ Building universal Go helper (arm64 + amd64)…"
( cd relay-helper
  CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -o relay-helper.arm64 .
  CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -o relay-helper.amd64 .
  lipo -create -output relay-helper relay-helper.arm64 relay-helper.amd64
  rm -f relay-helper.arm64 relay-helper.amd64 )

echo "→ Generating project + building Release…"
xcodegen generate >/dev/null
DEVELOPER_DIR="$DEV" xcodebuild -project Relay.xcodeproj -scheme Relay \
  -configuration Release -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build >/dev/null

APP_SRC="build/Build/Products/Release/Relay.app"
[ -d "$APP_SRC" ] || { echo "error: build product missing" >&2; exit 1; }

rm -rf "$DIST"; mkdir -p "$DIST"
APP="$DIST/Relay.app"
cp -R "$APP_SRC" "$APP"

# --- bundle the Go backend + sign (hardened runtime + secure timestamp) -------
echo "→ Bundling helper…"
mkdir -p "$APP/Contents/Resources"
cp relay-helper/relay-helper "$APP/Contents/Resources/relay-helper"
codesign --force --options runtime --timestamp \
  --sign "$IDENTITY" "$APP/Contents/Resources/relay-helper"

# Sign embedded frameworks + their nested helpers (Sparkle ships Autoupdate,
# Updater.app and XPC services that must each be signed from the inside out,
# BEFORE the outer app, or notarization rejects the bundle).
if [ -d "$APP/Contents/Frameworks" ]; then
  echo "→ Signing embedded frameworks…"
  # Nested helpers first (deepest), at any depth — Sparkle's XPC services live under
  # Sparkle.framework/Versions/B/XPCServices, plus Autoupdate + Updater.app.
  find "$APP/Contents/Frameworks" \( -name "*.xpc" -o -name "*.app" -o -name "Autoupdate" -o -name "*.dylib" \) -print0 \
    | while IFS= read -r -d '' nested; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$nested"
  done
  # Then the frameworks themselves.
  find "$APP/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0 \
    | while IFS= read -r -d '' fw; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$fw"
  done
fi

echo "→ Signing app with Developer ID…"
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# --- notarize ----------------------------------------------------------------
ZIP="$DIST/Relay.zip"
echo "→ Zipping + submitting to Apple notary service (this can take a few minutes)…"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# --- staple + verify ---------------------------------------------------------
echo "→ Stapling ticket…"
xcrun stapler staple "$APP"
spctl -a -t exec -vv "$APP" 2>&1 | sed 's/^/  /'

# refresh the zip with the stapled app (used by Sparkle's appcast)
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- build a drag-to-Applications DMG, then notarize + staple it -------------
DMG="$DIST/Relay.dmg"
echo "→ Building DMG…"
STAGING="$DIST/dmg-staging"
rm -rf "$STAGING"; mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/Relay.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Relay" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "→ Notarizing DMG…"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /' || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1")

# --- Sparkle appcast (EdDSA-signed; private key lives in your Keychain) -------
# generate_appcast comes from the Sparkle tools. Set GENAPPCAST, or download the
# Sparkle release tarball into .sparkle-tools/ (see RELEASE.md).
GENAPPCAST="${GENAPPCAST:-$ROOT/.sparkle-tools/bin/generate_appcast}"
if [ ! -x "$GENAPPCAST" ]; then
  GENAPPCAST=$(find "$ROOT/build" -name generate_appcast -type f 2>/dev/null | head -1)
fi
APPCAST="$DIST/appcast.xml"
if [ -n "${GENAPPCAST:-}" ] && [ -x "$GENAPPCAST" ]; then
  echo "→ Generating signed appcast…"
  APPCAST_SRC="$DIST/appcast-src"; rm -rf "$APPCAST_SRC"; mkdir -p "$APPCAST_SRC"
  cp "$ZIP" "$APPCAST_SRC/"
  "$GENAPPCAST" --download-url-prefix "https://github.com/hatimhtm/Relay/releases/download/v$VERSION/" "$APPCAST_SRC"
  mv "$APPCAST_SRC/appcast.xml" "$APPCAST"
  rm -rf "$APPCAST_SRC"
else
  echo "⚠ generate_appcast not found — skipping appcast (auto-update won't update without it)." >&2
  echo "  Download the Sparkle tools into .sparkle-tools/ or set GENAPPCAST — see RELEASE.md." >&2
  APPCAST=""
fi

echo "✓ Done."
echo "  Notarized app: $APP"
echo "  DMG (direct download): $DMG"
echo "  Zip (Sparkle update):  $ZIP"
[ -n "$APPCAST" ] && echo "  Appcast (auto-update): $APPCAST"
echo
echo "Publish the release with the GitHub CLI (tag MUST be v$VERSION to match the appcast URLs):"
if [ -n "$APPCAST" ]; then
  echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" \"$APPCAST\" --title \"Relay v$VERSION\" --notes \"…\""
else
  echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"Relay v$VERSION\" --notes \"…\""
fi
echo "Bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in project.yml before each release."
