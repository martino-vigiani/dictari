#!/bin/bash
# Dictari — build the Debug app, sign it, install it in /Applications and relaunch.
#
# Signing is read from the environment:
#   DICTARI_SIGN_IDENTITY  e.g. "Developer ID Application: Your Name (TEAMID1234)" or an
#                          "Apple Development: ..." identity (see: security find-identity -v -p codesigning)
#   DICTARI_TEAM_ID        the team that identity belongs to
# macOS TCC keys Accessibility / Microphone grants on the designated requirement. With a real
# identity the requirement is stable, so you grant each permission once; the pre-install
# comparison below refuses an identity drift before it can replace the app. Without one the
# script signs ad-hoc, which works but makes macOS ask for both permissions again after every
# rebuild.
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJ_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
SIGN_ID="${DICTARI_SIGN_IDENTITY:-}"
EXPECTED_TEAM_ID="${DICTARI_TEAM_ID:-}"
# This script owns the developer copy in /Applications and always builds Debug: it is the
# configuration that carries the DEBUG condition and the development-only behaviour. Release
# artifacts come from release.sh and must not replace the local development copy.
BUILD_CONFIGURATION="Debug"
cd "$PROJ_DIR"
AD_HOC=0
# Hardened runtime on an ad-hoc signature makes dyld reject the Debug dylib (no Team ID to match),
# so ad-hoc builds are signed without it.
RUNTIME_OPTS=(--options runtime)
if [ -z "$SIGN_ID" ]; then
  AD_HOC=1
  SIGN_ID="-"
  RUNTIME_OPTS=()
  echo "warning: DICTARI_SIGN_IDENTITY is not set; building with an ad-hoc signature." >&2
  echo "         macOS will ask for Microphone and Accessibility again after every rebuild." >&2
  echo "         Set DICTARI_SIGN_IDENTITY and DICTARI_TEAM_ID to keep the grants." >&2
elif ! security find-identity -v -p codesigning | grep -Fq "$SIGN_ID"; then
  echo "Signing identity not found in the keychain: $SIGN_ID" >&2
  exit 1
fi
xcodegen generate >/dev/null
# A prior release build may have written command-line version overrides into this same DerivedData
# product. Xcode does not always re-run ProcessInfoPlistFile when only those overrides disappear,
# leaving a new binary inside a stale-version bundle. Make the declared plist input current so the
# generated Debug bundle always reflects project.yml.
touch "$PROJ_DIR/Sources/Dictari/App/Info.plist"
BUILD_LOG="$(mktemp -t dictari-build.XXXXXX)"
# Optimize Swift code (FluidAudio and WhisperKit above all) while keeping the Debug configuration
# and its DEBUG condition. In Debug, Xcode compiles SwiftPM packages with -Onone, and that made
# Parakeet ~30% slower than Release on the same clip (170 vs 131 ms for 21 s of audio,
# TranscriptionLatencyBenchmarkTests). Settings in project.yml never reach package targets; only a
# command-line override does. It optimizes the app's own code too, which measured neutral.
if ! xcodebuild -project Dictari.xcodeproj -scheme Dictari -configuration "$BUILD_CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO \
  SWIFT_OPTIMIZATION_LEVEL=-O \
  >"$BUILD_LOG" 2>&1; then
  grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" "$BUILD_LOG" || tail -n 80 "$BUILD_LOG"
  /bin/rm -f "$BUILD_LOG"
  exit 1
fi
grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" "$BUILD_LOG" || true
/bin/rm -f "$BUILD_LOG"

# Asked for, never hardcoded: the DerivedData directory carries a hash that changes whenever
# the project is regenerated with different dependencies. A pinned path silently points at a
# stale build — or at nothing — the first time a package is added.
BUILD_SETTINGS="$(xcodebuild -project Dictari.xcodeproj -scheme Dictari \
  -configuration "$BUILD_CONFIGURATION" -destination 'platform=macOS,arch=arm64' \
  -showBuildSettings 2>/dev/null)"
RESOLVED_CONFIGURATION="$(awk -F' = ' '/ CONFIGURATION = /{print $2; exit}' <<<"$BUILD_SETTINGS")"
SWIFT_CONDITIONS="$(awk -F' = ' '/ SWIFT_ACTIVE_COMPILATION_CONDITIONS = /{print $2; exit}' <<<"$BUILD_SETTINGS")"
if [ "$RESOLVED_CONFIGURATION" != "Debug" ]; then
  echo "Refusing to install a non-Debug build over the local development copy." >&2
  exit 1
fi
case " $SWIFT_CONDITIONS " in
  *" DEBUG "*) ;;
  *)
    echo "Refusing to install a build without the DEBUG condition over the local development copy." >&2
    exit 1
    ;;
esac
APP="$(awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}' <<<"$BUILD_SETTINGS")/Dictari.app"
INSTALL_APP="/Applications/Dictari.app"
INSTALL_STAGE="/Applications/.Dictari-install-$$.app"
INSTALL_OLD="/Applications/.Dictari-old-$$.app"
BACKUP_DIR="$HOME/Library/Application Support/Dictari/App Backups"
BACKUP_ZIP="$BACKUP_DIR/Dictari-previous.zip"

if [ ! -d "$APP" ]; then
  echo "Build product not found at: $APP" >&2
  exit 1
fi

pkill -f "Dictari.app/Contents/MacOS/Dictari" 2>/dev/null || true
sleep 1

# Inside-out, never --deep. `--deep` re-signs every nested binary with the APP's entitlements,
# which Sparkle's documentation explicitly warns against: its XPC services and the Autoupdate
# helper need their own signatures, and flattening them makes the updater refuse to start.
find "$APP/Contents/Frameworks" -name "*.xpc" -maxdepth 3 -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" {} 2>/dev/null || true

find "$APP/Contents/Frameworks" -name "Autoupdate" -o -name "Updater.app" -maxdepth 4 -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" {} 2>/dev/null || true

for fw in "$APP"/Contents/Frameworks/*.framework; do
  [ -d "$fw" ] && codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" "$fw"
done

# Debug builds emit Dictari.debug.dylib next to the executable. It has to carry the same Team
# ID as the process that loads it or dyld refuses it and the app dies at launch — which is
# exactly what `--deep` used to paper over.
find "$APP/Contents/MacOS" -name "*.dylib" -print0 2>/dev/null \
  | xargs -0 -I{} codesign --force "${RUNTIME_OPTS[@]}" --sign "$SIGN_ID" {}

codesign --force "${RUNTIME_OPTS[@]}" \
  --entitlements "$PROJ_DIR/Sources/Dictari/App/Dictari.entitlements" \
  --sign "$SIGN_ID" "$APP"

# Always launch the canonical installed copy. Launching a DerivedData product lets later
# unsigned build-only runs replace the executable behind the same path, which makes macOS see
# another code identity and ask for Microphone/Accessibility again. It also leaves LaunchServices
# free to reopen an older /Applications copy after a reboot.
codesign --verify --deep --strict "$APP"
SIGNING_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if [ "$AD_HOC" = "0" ] && [ -n "$EXPECTED_TEAM_ID" ]; then
  grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<<"$SIGNING_DETAILS" || {
    echo "Refusing to install a build signed by a different team than DICTARI_TEAM_ID." >&2
    exit 1
  }
fi

designated_requirement() {
  codesign -d -r- "$1" 2>&1 | sed -n 's/^designated => //p'
}

CANDIDATE_REQUIREMENT="$(designated_requirement "$APP")"
if [ -z "$CANDIDATE_REQUIREMENT" ]; then
  echo "Could not read the candidate app's designated requirement." >&2
  exit 1
fi
if [ "$AD_HOC" = "0" ] && [ -d "$INSTALL_APP" ]; then
  INSTALLED_REQUIREMENT="$(designated_requirement "$INSTALL_APP")"
  if [ -z "$INSTALLED_REQUIREMENT" ] || [ "$CANDIDATE_REQUIREMENT" != "$INSTALLED_REQUIREMENT" ]; then
    echo "Refusing to replace Dictari with a build whose identity would invalidate TCC grants." >&2
    echo "Installed: ${INSTALLED_REQUIREMENT:-<unavailable>}" >&2
    echo "Candidate: $CANDIDATE_REQUIREMENT" >&2
    exit 1
  fi
fi
ditto "$APP" "$INSTALL_STAGE"
codesign --verify --deep --strict "$INSTALL_STAGE"

mkdir -p "$BACKUP_DIR"
if [ -d "$INSTALL_APP" ]; then
  BACKUP_TEMP_DIR="$(mktemp -d /tmp/dictari-backup.XXXXXX)"
  ditto -c -k --sequesterRsrc --keepParent "$INSTALL_APP" \
    "$BACKUP_TEMP_DIR/Dictari-previous.zip"
  mv -f "$BACKUP_TEMP_DIR/Dictari-previous.zip" "$BACKUP_ZIP"
  rmdir "$BACKUP_TEMP_DIR"
  mv "$INSTALL_APP" "$INSTALL_OLD"
fi

if ! mv "$INSTALL_STAGE" "$INSTALL_APP"; then
  [ -d "$INSTALL_OLD" ] && mv "$INSTALL_OLD" "$INSTALL_APP"
  exit 1
fi

# The replacement is verified and the previous app is recoverable from BACKUP_ZIP.
[ -d "$INSTALL_OLD" ] && rm -rf "$INSTALL_OLD"
open "$INSTALL_APP"
if [ "$AD_HOC" = "1" ]; then
  echo "Installed and launched the Debug build at $INSTALL_APP (ad-hoc signature)."
  echo "Grant Microphone and Accessibility again if macOS asks; set DICTARI_SIGN_IDENTITY to avoid it."
else
  echo "Installed and launched the Debug build at $INSTALL_APP (stable signing requirement)."
  echo "TCC grants persist across rebuilds; release artifacts remain separate."
fi
