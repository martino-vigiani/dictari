#!/bin/bash
# Build and publish one signed Dictari update to the public Sparkle feed.
#
# Usage:
#   ./scripts/publish-update.sh 0.2.0 7
#
# Needs your own Apple Developer ID and notarization profile:
#   DICTARI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID1234)" \
#   DICTARI_TEAM_ID="TEAMID1234" NOTARY_PROFILE="dictari-notary" \
#   ./scripts/publish-update.sh 0.2.0 7
#
# After the Sparkle feed is live it also creates a GitHub release v<version> on the source repo
# (DICTARI_SOURCE_REPO, default martino-vigiani/dictari) with the DMG attached as Dictari.dmg,
# so https://github.com/<repo>/releases/latest/download/Dictari.dmg always resolves.
#
# For a same-Mac end-to-end test only:
#   ALLOW_DEVELOPMENT_UPDATE=1 ./scripts/publish-update.sh 0.1.1 2

set -euo pipefail

GH_BIN="${DICTARI_GH_BIN:-gh}"
CURL_BIN="${DICTARI_CURL_BIN:-curl}"
XMLLINT_BIN="${DICTARI_XMLLINT_BIN:-xmllint}"
TMP_ROOT=""
ACTIVE_MOUNT=""
PENDING_PUBLICATION=""

cleanup() {
  if [[ -n "$ACTIVE_MOUNT" ]]; then
    hdiutil detach "$ACTIVE_MOUNT" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PENDING_PUBLICATION" && -d "$PENDING_PUBLICATION" ]]; then
    rm -rf -- "$PENDING_PUBLICATION"
  fi
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf -- "$TMP_ROOT"
  fi
}

is_semver() {
  [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]]
}

# Prints -1, 0 or 1. Inputs must already have passed is_semver.
semver_compare() {
  local left="$1"
  local right="$2"
  local left_main="${left%%-*}"
  local right_main="${right%%-*}"
  local left_pre=""
  local right_pre=""
  local left_parts right_parts
  local index left_value right_value

  [[ "$left" == *-* ]] && left_pre="${left#*-}"
  [[ "$right" == *-* ]] && right_pre="${right#*-}"
  IFS='.' read -r -a left_parts <<< "$left_main"
  IFS='.' read -r -a right_parts <<< "$right_main"

  for index in 0 1 2; do
    if (( 10#${left_parts[$index]} < 10#${right_parts[$index]} )); then
      echo -1
      return
    fi
    if (( 10#${left_parts[$index]} > 10#${right_parts[$index]} )); then
      echo 1
      return
    fi
  done

  if [[ -z "$left_pre" && -z "$right_pre" ]]; then
    echo 0
    return
  fi
  if [[ -z "$left_pre" ]]; then
    echo 1
    return
  fi
  if [[ -z "$right_pre" ]]; then
    echo -1
    return
  fi

  IFS='.' read -r -a left_parts <<< "$left_pre"
  IFS='.' read -r -a right_parts <<< "$right_pre"
  index=0
  while (( index < ${#left_parts[@]} || index < ${#right_parts[@]} )); do
    if (( index >= ${#left_parts[@]} )); then
      echo -1
      return
    fi
    if (( index >= ${#right_parts[@]} )); then
      echo 1
      return
    fi

    left_value="${left_parts[$index]}"
    right_value="${right_parts[$index]}"
    if [[ "$left_value" == "$right_value" ]]; then
      ((index += 1))
      continue
    fi
    if [[ "$left_value" =~ ^[0-9]+$ && "$right_value" =~ ^[0-9]+$ ]]; then
      if (( 10#$left_value < 10#$right_value )); then echo -1; else echo 1; fi
      return
    fi
    if [[ "$left_value" =~ ^[0-9]+$ ]]; then
      echo -1
      return
    fi
    if [[ "$right_value" =~ ^[0-9]+$ ]]; then
      echo 1
      return
    fi
    if [[ "$left_value" < "$right_value" ]]; then echo -1; else echo 1; fi
    return
  done

  echo 0
}

read_feed_bounds() {
  local feed="$1"
  local item_count index build version comparison

  "$XMLLINT_BIN" --nonet --noout "$feed"
  item_count="$("$XMLLINT_BIN" --xpath 'count(//*[local-name()="item"])' "$feed")"
  [[ "$item_count" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: published appcast contains no release items"
    return 1
  }

  PARSED_FIRST_BUILD=""
  PARSED_FIRST_VERSION=""
  PARSED_MAX_BUILD=0
  PARSED_MAX_VERSION=""
  for ((index = 1; index <= item_count; index += 1)); do
    build="$("$XMLLINT_BIN" --xpath \
      "string((//*[local-name()='item'])[$index]/*[local-name()='version'])" "$feed")"
    version="$("$XMLLINT_BIN" --xpath \
      "string((//*[local-name()='item'])[$index]/*[local-name()='shortVersionString'])" "$feed")"
    [[ "$build" =~ ^[1-9][0-9]*$ ]] || {
      echo "error: appcast item $index has an invalid sparkle:version"
      return 1
    }
    is_semver "$version" || {
      echo "error: appcast item $index has an invalid semantic version: $version"
      return 1
    }

    if (( index == 1 )); then
      PARSED_FIRST_BUILD="$build"
      PARSED_FIRST_VERSION="$version"
    fi
    if (( build > PARSED_MAX_BUILD )); then
      PARSED_MAX_BUILD="$build"
    fi
    if [[ -z "$PARSED_MAX_VERSION" ]]; then
      PARSED_MAX_VERSION="$version"
    else
      comparison="$(semver_compare "$version" "$PARSED_MAX_VERSION")"
      if (( comparison > 0 )); then
        PARSED_MAX_VERSION="$version"
      fi
    fi
  done
}

api_response_is_404() {
  local response="$1"
  local error_file="$2"
  [[ "$(printf '%s' "$response" | jq -r '.status // empty' 2>/dev/null || true)" == "404" ]] \
    || grep -Eq 'HTTP[^0-9]*404|HTTP 404|Not Found.*404' "$error_file"
}

snapshot_feed() {
  local response error_file encoding
  error_file="$TMP_ROOT/feed-api.err"

  if response="$("$GH_BIN" api "$FEED_ENDPOINT" 2>"$error_file")"; then
    PUBLISHED_FEED_SHA="$(printf '%s' "$response" | jq -er '.sha')"
    encoding="$(printf '%s' "$response" | jq -er '.encoding')"
    [[ "$PUBLISHED_FEED_SHA" =~ ^[0-9a-f]{40}$ && "$encoding" == "base64" ]] || {
      echo "error: GitHub returned an invalid appcast snapshot"
      return 1
    }
    printf '%s' "$response" \
      | jq -er '.content' \
      | /usr/bin/base64 -D > "$PUBLISHED_FEED_FILE"
    read_feed_bounds "$PUBLISHED_FEED_FILE" || return 1
    PUBLISHED_FEED_EXISTS=1
    return
  fi

  if api_response_is_404 "$response" "$error_file"; then
    PUBLISHED_FEED_SHA=""
    PUBLISHED_FEED_EXISTS=0
    return
  fi

  echo "error: could not take an authoritative GitHub appcast snapshot"
  sed -n '1,8p' "$error_file" >&2
  return 1
}

snapshot_release() {
  local response error_file
  error_file="$TMP_ROOT/release-api.err"

  if response="$("$GH_BIN" api "$RELEASE_ENDPOINT" 2>"$error_file")"; then
    printf '%s' "$response" | jq -e '.assets | type == "array"' >/dev/null || {
      echo "error: GitHub returned an invalid release snapshot"
      return 1
    }
    RELEASE_JSON="$response"
    RELEASE_EXISTS=1
    return
  fi

  if api_response_is_404 "$response" "$error_file"; then
    RELEASE_JSON='{"assets":[]}'
    RELEASE_EXISTS=0
    return
  fi

  echo "error: could not take an authoritative GitHub release snapshot"
  sed -n '1,8p' "$error_file" >&2
  return 1
}

asset_url_from_snapshot() {
  local asset_name="$1"
  printf '%s' "$RELEASE_JSON" | jq -er --arg name "$asset_name" '
    [.assets[] | select(.name == $name)] as $matches
    | if ($matches | length) == 1 then $matches[0].browser_download_url else empty end
  ' 2>/dev/null
}

download_bytes() {
  local url="$1"
  local destination="$2"
  local separator='?'
  [[ "$url" == *\?* ]] && separator='&'
  "$CURL_BIN" --fail --silent --show-error --location \
    --header 'Cache-Control: no-cache' \
    "${url}${separator}dictari_download=$(date +%s)" \
    -o "$destination"
}

verify_published_bytes() {
  local expected="$1"
  local url="$2"
  local label="$3"
  local downloaded separator attempt
  downloaded="$TMP_ROOT/verify-$(basename "$expected")-$$"
  separator='?'
  [[ "$url" == *\?* ]] && separator='&'

  for ((attempt = 1; attempt <= VERIFY_ATTEMPTS; attempt += 1)); do
    if "$CURL_BIN" --fail --silent --show-error --location \
      --header 'Cache-Control: no-cache' \
      "${url}${separator}dictari_verify=$(date +%s)-$attempt" \
      -o "$downloaded" && cmp -s "$expected" "$downloaded"; then
      rm -f "$downloaded"
      echo "Verified published bytes: $label"
      return 0
    fi
    if (( attempt < VERIFY_ATTEMPTS )) && [[ "$VERIFY_DELAY_SECONDS" != "0" ]]; then
      sleep "$VERIFY_DELAY_SECONDS"
    fi
  done

  echo "error: public $label does not match the approved transaction bytes"
  [[ -f "$downloaded" ]] && shasum -a 256 "$expected" "$downloaded"
  rm -f "$downloaded"
  return 1
}

publish_feed_cas() {
  local content
  content="$(base64 < "$APPCAST" | tr -d '\n')"

  if [[ -n "$PUBLISHED_FEED_SHA" ]]; then
    "$GH_BIN" api --method PUT "$FEED_ENDPOINT" \
      -f message="Publish Dictari $VERSION ($BUILD_NUMBER)" \
      -f content="$content" \
      -f sha="$PUBLISHED_FEED_SHA" >/dev/null || {
        echo "error: appcast changed concurrently; the newer feed was left untouched"
        return 1
      }
  else
    "$GH_BIN" api --method PUT "$FEED_ENDPOINT" \
      -f message="Publish Dictari $VERSION ($BUILD_NUMBER)" \
      -f content="$content" >/dev/null || {
        echo "error: appcast bootstrap lost a concurrent create race"
        return 1
      }
  fi
}

validate_candidate_dmg() {
  local dmg="$1"
  local mount_dir app_path actual_version actual_build codesign_info
  mount_dir="$TMP_ROOT/mount"
  mkdir -p "$mount_dir"

  hdiutil attach -nobrowse -readonly -mountpoint "$mount_dir" "$dmg" >/dev/null
  ACTIVE_MOUNT="$mount_dir"
  app_path="$(find "$mount_dir" -maxdepth 1 -type d -name 'Dictari.app' -print -quit)"
  [[ -n "$app_path" ]] || {
    echo "error: update DMG does not contain Dictari.app"
    return 1
  }

  actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$app_path/Contents/Info.plist")"
  actual_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$app_path/Contents/Info.plist")"
  [[ "$actual_version" == "$VERSION" && "$actual_build" == "$BUILD_NUMBER" ]] || {
    echo "error: archived bundle is $actual_version ($actual_build), expected $VERSION ($BUILD_NUMBER)"
    return 1
  }
  codesign --verify --deep --strict "$app_path"
  codesign_info="$(codesign -dvv "$app_path" 2>&1)"
  printf '%s' "$codesign_info" | grep -Fq "Authority=$SIGNING_IDENTITY" || {
    echo "error: archived bundle was not signed by $SIGNING_IDENTITY"
    return 1
  }
  if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
    xcrun stapler validate "$dmg" >/dev/null || {
      echo "error: Developer ID update DMG has no valid notarization ticket"
      return 1
    }
    spctl -a -t exec -vv "$app_path" >/dev/null || {
      echo "error: Developer ID update app was rejected by Gatekeeper"
      return 1
    }
  fi

  hdiutil detach "$ACTIVE_MOUNT" >/dev/null
  ACTIVE_MOUNT=""
}

copy_feed_assets_to_clean_stage() {
  local attributes url asset_name asset_url destination
  [[ "$PUBLISHED_FEED_EXISTS" == "1" ]] || return

  attributes="$("$XMLLINT_BIN" --xpath \
    '//*[local-name()="enclosure"]/@url' "$PUBLISHED_FEED_FILE")"
  while IFS= read -r url; do
    [[ "$url" == "$DOWNLOAD_PREFIX/"* ]] || {
      echo "error: published appcast references an unexpected asset host: $url"
      return 1
    }
    asset_name="${url##*/}"
    [[ "$asset_name" =~ ^[A-Za-z0-9._-]+$ ]] || {
      echo "error: unsafe asset name in appcast: $asset_name"
      return 1
    }
    destination="$STAGE_DIR/$asset_name"
    [[ -f "$destination" ]] && continue
    asset_url="$(asset_url_from_snapshot "$asset_name" || true)"
    [[ -n "$asset_url" ]] || {
      echo "error: appcast asset is missing from the authoritative release: $asset_name"
      return 1
    }
    download_bytes "$asset_url" "$destination"
  done < <(printf '%s' "$attributes" | grep -o 'url="[^"]*"' | sed 's/^url="//; s/"$//')
}

validate_generated_feed_assets() {
  local attributes url asset_name
  attributes="$("$XMLLINT_BIN" --xpath '//*[local-name()="enclosure"]/@url' "$APPCAST")"
  while IFS= read -r url; do
    [[ "$url" == "$DOWNLOAD_PREFIX/"* ]] || {
      echo "error: generated appcast references an unexpected asset host: $url"
      return 1
    }
    asset_name="${url##*/}"
    [[ -f "$STAGE_DIR/$asset_name" ]] || {
      echo "error: generated appcast references an unapproved artifact: $asset_name"
      return 1
    }
  done < <(printf '%s' "$attributes" | grep -o 'url="[^"]*"' | sed 's/^url="//; s/"$//')
}

load_or_create_publication() {
  local manifest="$PUBLICATION_DIR/manifest.json"
  local expected_base_sha candidate_sha artifact name sha
  local artifacts_json appcast_sha
  expected_base_sha="${PUBLISHED_FEED_SHA:-bootstrap}"
  candidate_sha="$(shasum -a 256 "$CANDIDATE_DMG" | awk '{print $1}')"

  if [[ -d "$PUBLICATION_DIR" ]]; then
    [[ -f "$manifest" ]] || {
      echo "error: incomplete publication transaction at $PUBLICATION_DIR"
      return 1
    }
    [[ "$(jq -er '.version' "$manifest")" == "$VERSION" \
      && "$(jq -er '.build' "$manifest")" == "$BUILD_NUMBER" \
      && "$(jq -er '.repository' "$manifest")" == "$UPDATE_REPO" \
      && "$(jq -er '.releaseTag' "$manifest")" == "$UPDATE_TAG" \
      && "$(jq -er '.keyAccount' "$manifest")" == "$KEY_ACCOUNT" \
      && "$(jq -er '.baseFeedSha' "$manifest")" == "$expected_base_sha" \
      && "$(jq -er '.signingIdentity' "$manifest")" == "$SIGNING_IDENTITY" \
      && "$(jq -er '.phase' "$manifest")" == "ready" \
      && "$(jq -er '.candidateSha256' "$manifest")" == "$candidate_sha" ]] || {
      echo "error: saved publication transaction does not match this request/feed snapshot"
      return 1
    }

    appcast_sha="$(jq -er '.appcastSha256' "$manifest")"
    [[ "$(shasum -a 256 "$PUBLICATION_DIR/appcast.xml" | awk '{print $1}')" == "$appcast_sha" ]] || {
      echo "error: saved transaction appcast failed its manifest hash"
      return 1
    }
    /usr/bin/ditto "$PUBLICATION_DIR/appcast.xml" "$STAGE_DIR/appcast.xml"

    while IFS=$'\t' read -r name sha; do
      [[ "$name" =~ ^[A-Za-z0-9._-]+$ && "$sha" =~ ^[0-9a-f]{64}$ ]] || {
        echo "error: invalid artifact entry in transaction manifest"
        return 1
      }
      artifact="$PUBLICATION_DIR/$name"
      [[ -f "$artifact" \
        && "$(shasum -a 256 "$artifact" | awk '{print $1}')" == "$sha" ]] || {
        echo "error: saved transaction artifact failed its manifest hash: $name"
        return 1
      }
      /usr/bin/ditto "$artifact" "$STAGE_DIR/$name"
    done < <(jq -r '.artifacts[] | [.name, .sha256] | @tsv' "$manifest")
    APPCAST="$STAGE_DIR/appcast.xml"
    echo "Reusing approved publication transaction: $PUBLICATION_DIR"
    return
  fi

  [[ ! -e "$PUBLICATION_DIR" ]] || {
    echo "error: publication transaction path is not a directory: $PUBLICATION_DIR"
    return 1
  }

  if [[ "$PUBLISHED_FEED_EXISTS" == "1" ]]; then
    /usr/bin/ditto "$PUBLISHED_FEED_FILE" "$STAGE_DIR/appcast.xml"
    copy_feed_assets_to_clean_stage
  fi
  /usr/bin/ditto "$CANDIDATE_DMG" "$STAGE_DIR/$(basename "$CANDIDATE_DMG")"

  echo "== Signing appcast =="
  "$GENERATE_APPCAST" \
    --account "$KEY_ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX/" \
    --maximum-versions 10 \
    "$STAGE_DIR"

  APPCAST="$STAGE_DIR/appcast.xml"
  [[ -f "$APPCAST" ]] || { echo "error: Sparkle did not produce appcast.xml"; return 1; }
  grep -q 'sparkle:edSignature=' "$APPCAST" || {
    echo "error: generated appcast has no EdDSA signature"
    return 1
  }
  read_feed_bounds "$APPCAST"
  [[ "$PARSED_FIRST_BUILD" == "$BUILD_NUMBER" \
    && "$PARSED_FIRST_VERSION" == "$VERSION" \
    && "$PARSED_MAX_BUILD" == "$BUILD_NUMBER" \
    && "$PARSED_MAX_VERSION" == "$VERSION" ]] || {
    echo "error: generated appcast latest release is not exactly $VERSION ($BUILD_NUMBER)"
    return 1
  }
  validate_generated_feed_assets

  PENDING_PUBLICATION="$TRANSACTION_DIR/.publication-$$.tmp"
  mkdir -p "$PENDING_PUBLICATION"
  /usr/bin/ditto "$APPCAST" "$PENDING_PUBLICATION/appcast.xml"
  artifacts_json='[]'
  shopt -s nullglob
  GENERATED_ARTIFACTS=("$STAGE_DIR"/*.dmg "$STAGE_DIR"/*.delta)
  shopt -u nullglob
  [[ ${#GENERATED_ARTIFACTS[@]} -gt 0 ]] || {
    echo "error: Sparkle generated no update artifacts"
    return 1
  }
  for artifact in "${GENERATED_ARTIFACTS[@]}"; do
    name="$(basename "$artifact")"
    sha="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    /usr/bin/ditto "$artifact" "$PENDING_PUBLICATION/$name"
    artifacts_json="$(printf '%s' "$artifacts_json" | jq \
      --arg name "$name" --arg sha "$sha" '. + [{name: $name, sha256: $sha}]')"
  done
  appcast_sha="$(shasum -a 256 "$APPCAST" | awk '{print $1}')"
  jq -n \
    --arg version "$VERSION" \
    --arg build "$BUILD_NUMBER" \
    --arg repository "$UPDATE_REPO" \
    --arg releaseTag "$UPDATE_TAG" \
    --arg keyAccount "$KEY_ACCOUNT" \
    --arg baseFeedSha "$expected_base_sha" \
    --arg signingIdentity "$SIGNING_IDENTITY" \
    --arg candidateSha256 "$candidate_sha" \
    --arg appcastSha256 "$appcast_sha" \
    --argjson artifacts "$artifacts_json" \
    '{version: $version, build: $build, repository: $repository,
      releaseTag: $releaseTag, keyAccount: $keyAccount, baseFeedSha: $baseFeedSha,
      signingIdentity: $signingIdentity, candidateSha256: $candidateSha256,
      appcastSha256: $appcastSha256, phase: "ready", artifacts: $artifacts}' \
    > "$PENDING_PUBLICATION/manifest.json"
  mv "$PENDING_PUBLICATION" "$PUBLICATION_DIR"
  PENDING_PUBLICATION=""
  echo "Saved retry-safe publication transaction: $PUBLICATION_DIR"
}

main() {
  local script_dir proj_dir version_arg build_arg
  local comparison signing_identity source_dmg shipped_key shipped_feed keychain_key
  local candidate_remote_url remote_candidate artifact asset_name asset_url
  local base_snapshot_key repo_key
  local -a missing_artifacts

  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  proj_dir="${DICTARI_PROJECT_DIR:-$(cd -- "$script_dir/.." && pwd -P)}"
  version_arg="${1:-}"
  build_arg="${2:-}"

  VERSION="$version_arg"
  BUILD_NUMBER="$build_arg"
  PRODUCTION_UPDATE_REPO="${DICTARI_PRODUCTION_UPDATE_REPO:-martino-vigiani/dictari-updates}"
  UPDATE_REPO="${DICTARI_UPDATE_REPO:-$PRODUCTION_UPDATE_REPO}"
  UPDATE_TAG="${DICTARI_UPDATE_TAG:-updates}"
  KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-dictari}"
  ALLOW_DEVELOPMENT_UPDATE="${ALLOW_DEVELOPMENT_UPDATE:-0}"
  DOWNLOAD_PREFIX="https://github.com/$UPDATE_REPO/releases/download/$UPDATE_TAG"
  FEED_URL="https://raw.githubusercontent.com/$UPDATE_REPO/main/appcast.xml"
  FEED_ENDPOINT="repos/$UPDATE_REPO/contents/appcast.xml"
  RELEASE_ENDPOINT="repos/$UPDATE_REPO/releases/tags/$UPDATE_TAG"
  repo_key="${UPDATE_REPO//\//-}"
  TRANSACTIONS_DIR="${DICTARI_TRANSACTIONS_DIR:-$proj_dir/build/update-transactions/$repo_key/$UPDATE_TAG}"
  VERIFY_ATTEMPTS="${DICTARI_VERIFY_ATTEMPTS:-5}"
  VERIFY_DELAY_SECONDS="${DICTARI_VERIFY_DELAY_SECONDS:-2}"

  if [[ -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
    echo "usage: $0 <marketing-version> <build-number>"
    return 64
  fi
  is_semver "$VERSION" || {
    echo "error: version must be SemVer (for example 0.2.0 or 0.2.0-beta.1): $VERSION"
    return 64
  }
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || {
    echo "error: build number must be a positive integer: $BUILD_NUMBER"
    return 64
  }
  [[ "$VERIFY_ATTEMPTS" =~ ^[1-9][0-9]*$ \
    && "$VERIFY_DELAY_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
    echo "error: invalid verification retry configuration"
    return 64
  }

  command -v "$GH_BIN" >/dev/null || { echo "error: GitHub CLI (gh) is required"; return 1; }
  command -v "$CURL_BIN" >/dev/null || { echo "error: curl is required"; return 1; }
  command -v "$XMLLINT_BIN" >/dev/null || { echo "error: xmllint is required"; return 1; }
  "$GH_BIN" auth status >/dev/null

  TMP_ROOT="$(mktemp -d /tmp/dictari-publish.XXXXXX)"
  trap cleanup EXIT
  PUBLISHED_FEED_FILE="$TMP_ROOT/published-appcast.xml"
  STAGE_DIR="$TMP_ROOT/stage"
  mkdir -p "$STAGE_DIR"

  # Content and blob SHA come from one API snapshot. Only a confirmed 404 is a bootstrap.
  snapshot_feed
  if [[ "$PUBLISHED_FEED_EXISTS" == "1" ]]; then
    if (( BUILD_NUMBER <= PARSED_MAX_BUILD )); then
      echo "error: build $BUILD_NUMBER is not newer than published build $PARSED_MAX_BUILD"
      return 1
    fi
    comparison="$(semver_compare "$VERSION" "$PARSED_MAX_VERSION")"
    if (( comparison <= 0 )); then
      echo "error: version $VERSION is not newer than published version $PARSED_MAX_VERSION"
      return 1
    fi
  fi
  snapshot_release

  signing_identity="${DICTARI_SIGN_IDENTITY:-}"
  if [[ -z "$signing_identity" || -z "${DICTARI_TEAM_ID:-}" ]]; then
    echo "error: set DICTARI_SIGN_IDENTITY (your signing identity) and DICTARI_TEAM_ID (its team)"
    return 1
  fi
  SIGNING_IDENTITY="$signing_identity"
  if [[ "$SIGNING_IDENTITY" != Developer\ ID\ Application:* ]]; then
    if [[ "$ALLOW_DEVELOPMENT_UPDATE" != "1" ]]; then
      echo "error: public updates require a Developer ID Application identity"
      echo "For a same-Mac test only, set ALLOW_DEVELOPMENT_UPDATE=1."
      return 1
    fi
    if [[ "$UPDATE_REPO" == "$PRODUCTION_UPDATE_REPO" ]]; then
      echo "error: Apple Development updates are forbidden on the production channel"
      echo "Set DICTARI_UPDATE_REPO to an explicit non-production test repository."
      return 1
    fi
    echo "warning: publishing a same-Mac test signed with Apple Development"
  fi
  if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* && -z "${NOTARY_PROFILE:-}" ]]; then
    echo "error: public Developer ID updates must also set NOTARY_PROFILE"
    return 1
  fi

  PLIST="$proj_dir/Sources/Dictari/App/Info.plist"
  shipped_feed="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")"
  [[ "$shipped_feed" == "$FEED_URL" ]] || {
    echo "error: app feed does not match the requested update channel"
    echo "Info.plist: $shipped_feed"
    echo "Publisher:  $FEED_URL"
    return 1
  }

  TRANSACTION_DIR="$TRANSACTIONS_DIR/$VERSION-$BUILD_NUMBER"
  # A CAS conflict keeps the immutable candidate but regenerates the feed from the new base.
  # Each authoritative feed SHA therefore gets its own exact, retry-safe publication bundle.
  base_snapshot_key="${PUBLISHED_FEED_SHA:-bootstrap}"
  PUBLICATION_DIR="$TRANSACTION_DIR/publications/$base_snapshot_key"
  CANDIDATE_DMG="$TRANSACTION_DIR/Dictari-$VERSION.dmg"
  mkdir -p "$(dirname "$PUBLICATION_DIR")"

  # If an earlier attempt reached GitHub but not the feed, resume from those exact bytes.
  candidate_remote_url="$(asset_url_from_snapshot "$(basename "$CANDIDATE_DMG")" || true)"
  if [[ -n "$candidate_remote_url" ]]; then
    remote_candidate="$TMP_ROOT/remote-candidate.dmg"
    download_bytes "$candidate_remote_url" "$remote_candidate"
    if [[ -f "$CANDIDATE_DMG" ]]; then
      cmp -s "$CANDIDATE_DMG" "$remote_candidate" || {
        echo "error: saved candidate differs from the already-uploaded immutable DMG"
        return 1
      }
    else
      /usr/bin/ditto "$remote_candidate" "$CANDIDATE_DMG"
    fi
  fi

  if [[ ! -f "$CANDIDATE_DMG" ]]; then
    echo "== Building Dictari $VERSION ($BUILD_NUMBER) =="
    DICTARI_SIGN_IDENTITY="$SIGNING_IDENTITY" \
    DICTARI_TEAM_ID="$DICTARI_TEAM_ID" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    "${DICTARI_RELEASE_SCRIPT:-$script_dir/release.sh}"
    source_dmg="$proj_dir/build/release/Dictari.dmg"
    [[ -f "$source_dmg" ]] || { echo "error: release DMG was not produced"; return 1; }
    /usr/bin/ditto "$source_dmg" "$CANDIDATE_DMG"
  else
    echo "Reusing exact candidate bytes: $CANDIDATE_DMG"
  fi
  validate_candidate_dmg "$CANDIDATE_DMG"

  GENERATE_KEYS="$proj_dir/build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys"
  GENERATE_APPCAST="$proj_dir/build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
  [[ -x "$GENERATE_KEYS" && -x "$GENERATE_APPCAST" ]] || {
    echo "error: Sparkle publishing tools were not found in the resolved package artifacts"
    return 1
  }

  shipped_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
  keychain_key="$("$GENERATE_KEYS" --account "$KEY_ACCOUNT" -p)"
  [[ "$shipped_key" == "$keychain_key" ]] || {
    echo "error: Info.plist public key does not match Keychain account '$KEY_ACCOUNT'"
    return 1
  }

  load_or_create_publication
  APPCAST="$STAGE_DIR/appcast.xml"
  read_feed_bounds "$APPCAST"
  [[ "$PARSED_FIRST_BUILD" == "$BUILD_NUMBER" \
    && "$PARSED_FIRST_VERSION" == "$VERSION" \
    && "$PARSED_MAX_BUILD" == "$BUILD_NUMBER" \
    && "$PARSED_MAX_VERSION" == "$VERSION" ]] || {
    echo "error: approved transaction no longer describes exactly $VERSION ($BUILD_NUMBER)"
    return 1
  }
  validate_generated_feed_assets

  shopt -s nullglob
  ARTIFACTS=("$STAGE_DIR"/*.dmg "$STAGE_DIR"/*.delta)
  shopt -u nullglob
  [[ ${#ARTIFACTS[@]} -gt 0 ]] || { echo "error: no approved artifacts to upload"; return 1; }

  echo "== Validating immutable release assets =="
  # Pass 1 is read-only: every collision is checked before the first upload.
  missing_artifacts=()
  for artifact in "${ARTIFACTS[@]}"; do
    asset_name="$(basename "$artifact")"
    asset_url="$(asset_url_from_snapshot "$asset_name" || true)"
    if [[ -z "$asset_url" ]]; then
      missing_artifacts+=("$artifact")
      continue
    fi
    verify_published_bytes "$artifact" "$asset_url" "$asset_name"
    echo "Already published unchanged: $asset_name"
  done

  if [[ "$RELEASE_EXISTS" == "0" ]]; then
    "$GH_BIN" release create "$UPDATE_TAG" \
      --repo "$UPDATE_REPO" \
      --title "Dictari update archives" \
      --notes "Signed archives consumed by Dictari's Sparkle updater." \
      --prerelease
    RELEASE_EXISTS=1
  fi

  # Pass 2 mutates only after every pre-existing asset has proved immutable.
  for artifact in "${missing_artifacts[@]}"; do
    "$GH_BIN" release upload "$UPDATE_TAG" --repo "$UPDATE_REPO" "$artifact"
  done

  # Refresh and prove every referenced DMG/delta is publicly available before exposing the feed.
  snapshot_release
  [[ "$RELEASE_EXISTS" == "1" ]] || { echo "error: update release disappeared"; return 1; }
  for artifact in "${ARTIFACTS[@]}"; do
    asset_name="$(basename "$artifact")"
    asset_url="$(asset_url_from_snapshot "$asset_name" || true)"
    [[ -n "$asset_url" ]] || { echo "error: uploaded asset is missing: $asset_name"; return 1; }
    verify_published_bytes "$artifact" "$asset_url" "$asset_name"
  done

  # Publish last with the SHA captured before any work. A concurrent feed change makes this fail.
  echo "== Publishing appcast =="
  publish_feed_cas

  verify_published_bytes "$APPCAST" "$FEED_URL" "appcast.xml"
  echo "Published Dictari $VERSION ($BUILD_NUMBER)"
  echo "Feed: $FEED_URL"
  echo "DMG:  $DOWNLOAD_PREFIX/$(basename "$CANDIDATE_DMG")"

  # Stable download link for scripts/install.sh and the README: the asset must be named exactly
  # Dictari.dmg, so the exact candidate bytes are staged under that name. Runs after the feed is
  # live and is skipped when the release already exists, so a resumed publish stays idempotent.
  SOURCE_REPO="${DICTARI_SOURCE_REPO:-martino-vigiani/dictari}"
  if "$GH_BIN" release view "v$VERSION" --repo "$SOURCE_REPO" >/dev/null 2>&1; then
    echo "GitHub release v$VERSION already exists on $SOURCE_REPO; leaving it unchanged"
  else
    echo "== Creating GitHub release v$VERSION on $SOURCE_REPO =="
    mkdir -p "$TMP_ROOT/source-release"
    /usr/bin/ditto "$CANDIDATE_DMG" "$TMP_ROOT/source-release/Dictari.dmg"
    "$GH_BIN" release create "v$VERSION" "$TMP_ROOT/source-release/Dictari.dmg" \
      --repo "$SOURCE_REPO" \
      --title "Dictari $VERSION" \
      --generate-notes \
      --latest
    echo "Download: https://github.com/$SOURCE_REPO/releases/latest/download/Dictari.dmg"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
