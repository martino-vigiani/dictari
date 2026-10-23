#!/bin/zsh
# Refreshes Sources/Dictari/Resources/Localizable.xcstrings from the code.
#
# Xcode only syncs String Catalogs when building in the IDE. This builds the app with
# xcodebuild, collects the .stringsdata the compiler emits for every localizable literal
# (Text("…"), String(localized:), LocalizedStringResource, …), and merges them into the catalog
# with xcstringstool: new keys are added, keys no longer in the code are marked stale, and
# existing translations are kept.
set -euo pipefail
cd "${0:A:h}/.."
derived="${DICTARI_STRINGS_DERIVED:-$(mktemp -d)/dd}"
xcodegen generate >/dev/null
xcodebuild -project Dictari.xcodeproj -scheme Dictari -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$derived" \
  build CODE_SIGNING_ALLOWED=NO SWIFT_EMIT_LOC_STRINGS=YES >/dev/null
stringsdata=("${(@f)$(find "$derived/Build/Intermediates.noindex" -name '*.stringsdata' \
  -path '*Dictari*' -not -path '*DictariTests*' -not -path '*Packages*' | sort)}")
xcrun xcstringstool sync Sources/Dictari/Resources/Localizable.xcstrings --stringsdata "${stringsdata[@]}"
echo "Synced ${#stringsdata} stringsdata files."
