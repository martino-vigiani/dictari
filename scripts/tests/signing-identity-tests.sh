#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# No scripts may carry the maintainer's identity, team or home directory: contributors sign with
# their own, supplied through DICTARI_SIGN_IDENTITY / DICTARI_TEAM_ID.
hardcoded="$(grep -rnE 'Developer ID Application: [A-Za-z]+ [A-Za-z]+ \([A-Z0-9]{10}\)|/Users/[a-z]' \
  "$PROJECT_DIR/scripts" --include='*.sh' --include='*.md' --exclude='signing-identity-tests.sh' \
  | grep -v 'TEAMID' || true)"
[[ -z "$hardcoded" ]] \
  || fail "a script or doc under scripts/ hard-codes a personal identity or home directory: $hardcoded"
grep -Fq 'SIGN_ID="${DICTARI_SIGN_IDENTITY:-}"' "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh does not read the signing identity from DICTARI_SIGN_IDENTITY"
grep -Fq 'SIGN_ID="-"' "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh no longer falls back to an ad-hoc signature"
grep -Fq 'DICTARI_SIGN_IDENTITY' "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh does not read DICTARI_SIGN_IDENTITY"
grep -Fq -- '-z "${DICTARI_SIGN_IDENTITY:-}"' "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer fails when DICTARI_SIGN_IDENTITY is unset"
grep -Fq 'signing_identity="${DICTARI_SIGN_IDENTITY:-}"' "$PROJECT_DIR/scripts/publish-update.sh" \
  || fail "publish-update.sh does not read DICTARI_SIGN_IDENTITY"
grep -Fq 'CANDIDATE_REQUIREMENT="$(designated_requirement "$APP")"' \
  "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh no longer reads the candidate designated requirement"
grep -Fq '"$CANDIDATE_REQUIREMENT" != "$INSTALLED_REQUIREMENT"' \
  "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh no longer rejects a TCC identity drift"
grep -Fq 'BUILD_CONFIGURATION="Debug"' "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh no longer pins the installed developer copy to Debug"
grep -Fq 'SWIFT_ACTIVE_COMPILATION_CONDITIONS' "$PROJECT_DIR/scripts/build-run.sh" \
  || fail "build-run.sh no longer inspects the resolved Swift conditions"
grep -Fq -- '-configuration Release' "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer keeps public artifacts on Release"
# Regression: a signed app inside an unsigned DMG still leaves the downloaded
# container untrusted by Gatekeeper. The container must be signed before upload.
grep -Fq 'codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp \' \
  "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer signs the outer DMG with the Developer ID identity"
grep -Fq -- '-i "$BUNDLE_ID.dmg" "$DMG_PATH"' "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer signs the DMG path"
grep -Fq 'assert_signed_identity "$DMG_PATH"' "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer checks the DMG signing identity"
grep -Fq 'spctl -a -t open --context context:primary-signature -vvv "$DMG_PATH"' \
  "$PROJECT_DIR/scripts/release.sh" \
  || fail "release.sh no longer Gatekeeper-assesses the DMG itself"
dmg_sign_line="$(grep -nF 'codesign --sign "$DEVELOPER_ID_APPLICATION" --timestamp \' \
  "$PROJECT_DIR/scripts/release.sh" | cut -d: -f1)"
notary_submit_line="$(grep -nF 'xcrun notarytool submit "$DMG_PATH"' \
  "$PROJECT_DIR/scripts/release.sh" | cut -d: -f1)"
[[ "$dmg_sign_line" -lt "$notary_submit_line" ]] \
  || fail "release.sh must sign the DMG before submitting it for notarization"

echo "PASS: scripts take signing identity from the environment; local installs stay Debug; release keeps its signing checks"
