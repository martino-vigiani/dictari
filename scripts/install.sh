#!/bin/bash
# Install the latest Dictari release into /Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/martino-vigiani/dictari/main/scripts/install.sh | bash
#
# Downloads the notarized DMG from the latest GitHub release, replaces any existing
# /Applications/Dictari.app and launches it. Requires an Apple Silicon Mac on macOS 26 or later.
set -euo pipefail

DMG_URL="https://github.com/martino-vigiani/dictari/releases/latest/download/Dictari.dmg"
APP_NAME="Dictari"
DEST="/Applications/$APP_NAME.app"

TMP_DIR=""
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR"
  fi
}
trap cleanup EXIT

die() {
  echo "error: $*" >&2
  exit 1
}

[[ "$(uname -s)" == "Darwin" ]] || die "Dictari runs on macOS only."
[[ "$(uname -m)" == "arm64" ]] || die "Dictari needs an Apple Silicon Mac (arm64)."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$macos_major" =~ ^[0-9]+$ ]] && (( macos_major >= 26 )) \
  || die "Dictari needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."

TMP_DIR="$(mktemp -d /tmp/dictari-install.XXXXXX)"
DMG_PATH="$TMP_DIR/$APP_NAME.dmg"

echo "Downloading $APP_NAME..."
curl -fL --progress-bar -o "$DMG_PATH" "$DMG_URL"

echo "Mounting disk image..."
MOUNT_POINT="$TMP_DIR/mount"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -nobrowse -quiet -readonly -mountpoint "$MOUNT_POINT"
[[ -d "$MOUNT_POINT/$APP_NAME.app" ]] || die "$APP_NAME.app not found in the disk image."

# Quit a running copy so the bundle can be replaced; ignore errors if it is not running.
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
sleep 1

echo "Installing to $DEST..."
rm -rf -- "$DEST"
ditto "$MOUNT_POINT/$APP_NAME.app" "$DEST"

hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
MOUNT_POINT=""

# The app is notarized, so no quarantine workaround is needed.
open -a "$DEST"
echo "$APP_NAME installed. Grant Microphone and Accessibility access when macOS asks."
