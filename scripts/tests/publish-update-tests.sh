#!/bin/bash
# shellcheck disable=SC2016,SC2034

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PUBLISH_SCRIPT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)/publish-update.sh"
# shellcheck source=scripts/publish-update.sh
source "$PUBLISH_SCRIPT"

TEST_ROOT="$(mktemp -d /tmp/dictari-publisher-tests.XXXXXX)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_failure() {
  if "$@" > "$TEST_ROOT/expected-failure.log" 2>&1; then
    fail "expected failure: $*"
  fi
}

marker_line() {
  grep -nF "$1" "$PUBLISH_SCRIPT" | tail -1 | cut -d: -f1
}

FAKE_GH="$TEST_ROOT/gh"
cat > "$FAKE_GH" <<'FAKE_GH_SCRIPT'
#!/bin/bash
set -euo pipefail

case "${FAKE_GH_MODE:?}" in
  transport)
    echo 'gh: upstream unavailable (HTTP 503)' >&2
    exit 1
    ;;
  missing)
    echo '{"message":"Not Found","status":"404"}'
    echo 'gh: Not Found (HTTP 404)' >&2
    exit 1
    ;;
  feed)
    content="$(/usr/bin/base64 < "${FAKE_FEED_FILE:?}" | tr -d '\n')"
    jq -n --arg sha 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
      --arg content "$content" '{sha: $sha, encoding: "base64", content: $content}'
    ;;
  cas-ok)
    printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
    ;;
  cas-fail)
    printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
    exit 1
    ;;
  *)
    echo "unexpected fake gh mode: $FAKE_GH_MODE" >&2
    exit 2
    ;;
esac
FAKE_GH_SCRIPT
chmod +x "$FAKE_GH"

VALID_FEED="$TEST_ROOT/appcast.xml"
cat > "$VALID_FEED" <<'XML'
<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <item>
      <sparkle:version>7</sparkle:version>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
      <enclosure url="https://example.invalid/Dictari-0.2.0.dmg"/>
    </item>
  </channel>
</rss>
XML

MALFORMED_FEED="$TEST_ROOT/malformed.xml"
cat > "$MALFORMED_FEED" <<'XML'
<rss><channel><item></rss>
XML

# Semantic version ordering is portable and fail-closed for visible downgrades/equality.
is_semver 0.2.0 || fail 'valid SemVer was rejected'
is_semver 0.2.0-beta.2 || fail 'valid prerelease was rejected'
assert_failure is_semver 01.2.0
assert_failure is_semver 0.2.0.1
assert_equal "$(semver_compare 0.1.9 0.2.0)" '-1'
assert_equal "$(semver_compare 0.2.0 0.2.0)" '0'
assert_equal "$(semver_compare 0.2.0 0.2.0-rc.1)" '1'
assert_equal "$(semver_compare 0.2.0-beta.2 0.2.0-beta.10)" '-1'

# XML must parse and contain valid build/marketing versions before publication proceeds.
XMLLINT_BIN="$(command -v xmllint)"
read_feed_bounds "$VALID_FEED"
assert_equal "$PARSED_MAX_BUILD" '7'
assert_equal "$PARSED_MAX_VERSION" '0.2.0'
assert_failure read_feed_bounds "$MALFORMED_FEED"

# Only a confirmed 404 is bootstrap; transport/5xx and malformed 200 responses abort.
GH_BIN="$FAKE_GH"
FEED_ENDPOINT='repos/example/dictari/contents/appcast.xml'
TMP_ROOT="$TEST_ROOT/snapshot"
mkdir -p "$TMP_ROOT"
PUBLISHED_FEED_FILE="$TMP_ROOT/live.xml"
export FAKE_GH_MODE=transport
assert_failure snapshot_feed
export FAKE_GH_MODE=missing
snapshot_feed
assert_equal "$PUBLISHED_FEED_EXISTS" '0'
export FAKE_GH_MODE=feed FAKE_FEED_FILE="$MALFORMED_FEED"
assert_failure snapshot_feed
export FAKE_FEED_FILE="$VALID_FEED"
snapshot_feed
assert_equal "$PUBLISHED_FEED_EXISTS" '1'
assert_equal "$PUBLISHED_FEED_SHA" 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
assert_equal "$PARSED_MAX_BUILD" '7'

# The PUT uses the SHA captured with the feed bytes and never retries a failed CAS blindly.
APPCAST="$VALID_FEED"
VERSION='0.3.0'
BUILD_NUMBER='8'
FAKE_GH_LOG="$TEST_ROOT/gh.log"
export FAKE_GH_LOG
export FAKE_GH_MODE=cas-ok
publish_feed_cas
grep -Fq 'sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$FAKE_GH_LOG" \
  || fail 'CAS PUT did not use the captured feed SHA'
assert_equal "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')" '1'

export FAKE_GH_MODE=cas-fail
assert_failure publish_feed_cas
assert_equal "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')" '2'

# Keep the mutation order mechanically locked: validate collisions, upload, probe all, feed CAS.
collision_line="$(marker_line '# Pass 1 is read-only')"
upload_line="$(marker_line '# Pass 2 mutates')"
probe_line="$(marker_line '# Refresh and prove every referenced DMG/delta')"
feed_line="$(marker_line '# Publish last with the SHA captured before any work')"
(( collision_line < upload_line \
  && upload_line < probe_line \
  && probe_line < feed_line )) \
  || fail 'unsafe publication ordering in main()'

if grep -q -- '--clobber\|EXISTING_SHA' "$PUBLISH_SCRIPT"; then
  fail 'publisher contains a mutable upload or a fresh pre-PUT SHA lookup'
fi
grep -q 'for artifact in "${ARTIFACTS\[@\]}"' "$PUBLISH_SCRIPT" \
  || fail 'publisher no longer verifies the complete artifact set'
grep -q 'Apple Development updates are forbidden on the production channel' "$PUBLISH_SCRIPT" \
  || fail 'development builds can reach the production channel'
grep -q 'xcrun stapler validate "$dmg"' "$PUBLISH_SCRIPT" \
  || fail 'reused Developer ID archives are not checked for notarization'
grep -q 'spctl -a -t exec -vv "$app_path"' "$PUBLISH_SCRIPT" \
  || fail 'reused Developer ID apps are not checked by Gatekeeper'

echo 'PASS: Dictari publisher safety checks'
