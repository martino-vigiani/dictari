#!/bin/bash
# Dictari — build, sign, notarize and package a Developer ID release DMG.
#
# One-time setup the human must do before this script can run for real (see
# scripts/appcast.md for the full release checklist):
#
#   1. Create a notarytool keychain profile (stores an App Store Connect API key or
#      app-specific password in the login keychain, so this script never touches secrets):
#
#        xcrun notarytool store-credentials "dictari-notary" \
#          --apple-id "you@example.com" \
#          --team-id "TEAMID1234" \
#          --password "app-specific-password"
#
#   2. Generate the Sparkle EdDSA signing key (stored in the login keychain; prints the
#      public key that goes into Info.plist's SUPublicEDKey — see scripts/appcast.md):
#
#        <DerivedData or SPM checkout>/Sparkle/bin/generate_keys
#
# Usage:
#   DICTARI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
#   DICTARI_TEAM_ID="TEAMID1234" \
#   NOTARY_PROFILE="dictari-notary" \
#   MARKETING_VERSION="0.2.0" \
#   CURRENT_PROJECT_VERSION="7" \
#   ./scripts/release.sh
#
# DICTARI_SIGN_IDENTITY and DICTARI_TEAM_ID are required: only the holder of a Developer ID
# certificate can produce a release. Without NOTARY_PROFILE the script still runs (signed but
# unnotarized) as a smoke test of the packaging steps.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJ_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
cd "$PROJ_DIR"

# --- Configuration (override via env vars) ------------------------------------------------

# Your own Developer ID Application identity and its team. Direct development builds and releases
# should share one identity: alternating between Apple Development and Developer ID changes the
# designated requirement and invalidates the user's Accessibility and Microphone grants even when
# the bundle identifier stays unchanged.
if [[ -z "${DICTARI_SIGN_IDENTITY:-}" || -z "${DICTARI_TEAM_ID:-}" ]]; then
  echo "error: DICTARI_SIGN_IDENTITY and DICTARI_TEAM_ID must be set to build a release." >&2
  echo "  DICTARI_SIGN_IDENTITY=\"Developer ID Application: Your Name (TEAMID1234)\"" >&2
  echo "  DICTARI_TEAM_ID=\"TEAMID1234\"" >&2
  echo "List your identities with: security find-identity -v -p codesigning" >&2
  exit 1
fi
DEVELOPER_ID_APPLICATION="$DICTARI_SIGN_IDENTITY"
TEAM_ID="$DICTARI_TEAM_ID"

# Keychain profile created once via `notarytool store-credentials` (see header comment).
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

MARKETING_VERSION="${MARKETING_VERSION:-}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-}"

SCHEME="Dictari"
APP_NAME="Dictari"
BUNDLE_ID="com.subralabs.Dictari"
ENTITLEMENTS="$PROJ_DIR/Sources/Dictari/App/Dictari.entitlements"

BUILD_DIR="$PROJ_DIR/build/release"
ARCHIVE_DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$ARCHIVE_DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

echo "== Dictari release build =="
echo "Signing identity : $DEVELOPER_ID_APPLICATION"
echo "Team ID          : $TEAM_ID"
echo "Notary profile   : ${NOTARY_PROFILE:-<none — notarization will be skipped>}"
echo "Marketing version: ${MARKETING_VERSION:-<unchanged from project.yml>}"
echo "Build number     : ${CURRENT_PROJECT_VERSION:-<unchanged from project.yml>}"
echo

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- 1. Regenerate the project, then build Release ----------------------------------------

xcodegen generate >/dev/null

XCODEBUILD_ARGS=(
  -project "$PROJ_DIR/Dictari.xcodeproj" -scheme "$SCHEME" -configuration Release
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "$ARCHIVE_DERIVED_DATA"
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
  DEVELOPMENT_TEAM="$TEAM_ID"
  CODE_SIGN_STYLE=Manual
  ARCHS=arm64
  ONLY_ACTIVE_ARCH=YES
)
[[ -n "$MARKETING_VERSION" ]] && XCODEBUILD_ARGS+=(MARKETING_VERSION="$MARKETING_VERSION")
[[ -n "$CURRENT_PROJECT_VERSION" ]] && XCODEBUILD_ARGS+=(CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION")

# Keep the array non-empty so macOS's Bash 3.2 does not treat an empty expansion as an
# unbound variable under `set -u` when no version overrides were requested.
xcodebuild "${XCODEBUILD_ARGS[@]}" clean build

[[ -d "$APP_PATH" ]] || { echo "error: build did not produce $APP_PATH"; exit 1; }

# --- 2. Sign, inside-out ---------------------------------------------------------------
#
# Hardened runtime + notarization require every executable Mach-O to carry its own valid
# signature, signed from the innermost component outward. Sparkle 2.x ships its own
# XPC services and an `Autoupdate` helper tool inside Sparkle.framework — per Sparkle's
# sandboxing docs, do NOT `codesign --deep` the whole app bundle in one shot for these
# (it can sign them in the wrong order / with the wrong flags). Sign every nested
# component explicitly first, then sign the outer app last without --deep.
#
# Dictari is not sandboxed, so no extra entitlements are needed for Sparkle specifically —
# the app's own entitlements file is enough. See scripts/appcast.md.

sign() {
  local target="$1"
  codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$target"
  assert_signed_identity "$target"
}

sign_with_entitlements() {
  local target="$1"
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID_APPLICATION" "$target"
  assert_signed_identity "$target"
}

assert_signed_identity() {
  local target="$1"
  local details
  details="$(codesign -dv --verbose=4 "$target" 2>&1)"
  if ! grep -Eq '^Authority=.+' <<<"$details" || \
     ! grep -Eq '^TeamIdentifier=[A-Z0-9]+' <<<"$details"; then
    echo "error: nested component is ad-hoc or missing team identity: $target"
    echo "$details"
    exit 1
  fi
}

echo "== Signing nested components (inside-out) =="

SPARKLE_FW="$APP_PATH/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE_FW" ]]; then
  # a) Sparkle's XPC services (innermost)
  while IFS= read -r -d '' xpc; do
    echo "  xpc: $xpc"
    sign "$xpc"
  done < <(find "$SPARKLE_FW" -name "*.xpc" -print0)

  # b) Sparkle's Autoupdate helper tool
  AUTOUPDATE="$SPARKLE_FW/Versions/B/Autoupdate"
  if [[ -f "$AUTOUPDATE" ]]; then
    echo "  autoupdate: $AUTOUPDATE"
    sign "$AUTOUPDATE"
  fi

  # c) Sparkle's updater UI is a nested app with its own executable. The package ships it
  # ad-hoc signed; leaving it that way passes `codesign --deep` but fails Developer ID
  # notarization because it has no Authority or TeamIdentifier.
  UPDATER_APP="$SPARKLE_FW/Versions/B/Updater.app"
  if [[ -d "$UPDATER_APP" ]]; then
    echo "  updater app: $UPDATER_APP"
    sign "$UPDATER_APP"
  fi

  # d) Sparkle.framework itself
  echo "  framework: $SPARKLE_FW"
  sign "$SPARKLE_FW"
fi

# e) Any other embedded frameworks (WhisperKit, FluidAudio, etc.)
if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
  while IFS= read -r -d '' fw; do
    # Skip Sparkle.framework — already signed above with its own inside-out order.
    [[ "$fw" == "$SPARKLE_FW" ]] && continue
    echo "  framework: $fw"
    sign "$fw"
  done < <(find "$APP_PATH/Contents/Frameworks" -maxdepth 1 -name "*.framework" -print0)
fi

# f) The app bundle itself, last, with our entitlements. No --deep: everything nested is
# already signed correctly above.
echo "== Signing app bundle =="
sign_with_entitlements "$APP_PATH"

# --- 3. Verify signing before we go any further --------------------------------------------

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "codesign --verify OK"

# --- 4. Build the DMG ------------------------------------------------------------------

echo "== Building DMG =="
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "$APP_NAME" \
    --app-drop-link 600 185 \
    --icon "$APP_NAME.app" 200 185 \
    --window-size 800 400 \
    "$DMG_PATH" \
    "$APP_PATH"
else
  echo "create-dmg not found, falling back to hdiutil"
  STAGING="$BUILD_DIR/dmg-staging"
  mkdir -p "$STAGING"
  cp -R "$APP_PATH" "$STAGING/"
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_PATH"
  rm -rf "$STAGING"
fi

[[ -f "$DMG_PATH" ]] || { echo "error: DMG was not created"; exit 1; }

# Apple recommends signing the outer disk image as well as the app. Its own distinct
# identifier seals the volume contents and lets Gatekeeper assess the downloaded DMG
# before mounting, not only the app after mounting. Sign before notarizing/stapling.
echo "== Signing DMG container =="
codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp \
  -i "$BUNDLE_ID.dmg" "$DMG_PATH"
assert_signed_identity "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

# --- 5. Notarize -------------------------------------------------------------------------

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "== Notarizing =="
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "== Stapling =="
  xcrun stapler staple "$DMG_PATH"
else
  echo "NOTARY_PROFILE not set — skipping notarization and stapling."
  echo "Set NOTARY_PROFILE to the keychain profile created with"
  echo "\`xcrun notarytool store-credentials\` to notarize for real."
fi

# --- 6. Final verification ----------------------------------------------------------------

echo "== Final verification =="
codesign --verify --deep --strict "$APP_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
if [[ -n "$NOTARY_PROFILE" ]]; then
  # Assess both layers. A signed/notarized app inside an unsigned DMG is not a
  # complete distribution artifact for a first-time user opening the image.
  xcrun stapler validate "$DMG_PATH"
  spctl -a -t open --context context:primary-signature -vvv "$DMG_PATH"
  spctl -a -t exec -vvv "$APP_PATH"
else
  # A local packaging smoke test is Developer ID signed but not notarized. Still print the
  # assessment so the missing release gate cannot be mistaken for production readiness.
  spctl -a -t exec -vvv "$APP_PATH" || \
    echo "Gatekeeper rejection expected for the unnotarized local Developer ID bundle."
fi

echo
echo "Done: $DMG_PATH"
