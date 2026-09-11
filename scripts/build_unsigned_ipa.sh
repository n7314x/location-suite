#!/usr/bin/env bash
set -euo pipefail

# Canonical unsigned device build used by both pull-request and tagged-release CI.
# The caller may override these values, but signing is always disabled below.
project_path="${PROJECT_PATH:-ios/TLocation.xcodeproj}"
scheme="${SCHEME:-TLocation}"
configuration="${CONFIGURATION:-Release}"
ipa_name="${IPA_NAME:-LocationSuite.ipa}"
output_dir="${1:-${OUTPUT_DIR:-build/unsigned-ios}}"
expected_bundle_id="${EXPECTED_BUNDLE_ID:-vn.truongkma.tlocation}"
expected_display_name="${EXPECTED_DISPLAY_NAME:-Location Suite}"
expected_minimum_os="${EXPECTED_MINIMUM_OS:-17.4}"

case "$output_dir" in
  ""|/|.|..|~|"$HOME")
    echo "Refusing unsafe output directory: $output_dir" >&2
    exit 2
    ;;
esac

for tool in xcodebuild xcrun ditto zip unzip plutil lipo shasum; do
  command -v "$tool" >/dev/null || {
    echo "Required Apple build tool is unavailable: $tool" >&2
    exit 2
  }
done

test -f "$project_path/project.pbxproj"
test -f ios/TLocation/Info.plist
test -f ios/TLocation/TLocation.entitlements
test -f ios/TLocation/idevice/libidevice_ffi.a

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
work_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
work_dir="$(mktemp -d "$work_parent/location-suite-ios.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

archive_path="$work_dir/LocationSuite.xcarchive"
staging_path="$work_dir/ipa-staging"
verification_path="$work_dir/ipa-verification"
ipa_path="$output_dir/$ipa_name"
build_log="$output_dir/LocationSuite-xcodebuild.log"
metadata_path="$output_dir/build-metadata.json"

plutil -lint ios/TLocation/Info.plist
plutil -lint ios/TLocation/TLocation.entitlements
python3 -m json.tool ios/TLocation/TLocation.icon/icon.json >/dev/null
python3 -m json.tool contracts/route-v1.schema.json >/dev/null
python3 -m json.tool contracts/location-route-document-v1.schema.json >/dev/null

library_architectures="$(lipo -archs ios/TLocation/idevice/libidevice_ffi.a)"
case " $library_architectures " in
  *" arm64 "*) ;;
  *) echo "libidevice_ffi.a lacks the required arm64 device slice." >&2; exit 1 ;;
esac

xcodebuild_args=(
  archive
  -project "$project_path"
  -scheme "$scheme"
  -configuration "$configuration"
  -archivePath "$archive_path"
  -sdk iphoneos
  -destination 'generic/platform=iOS'
  ONLY_ACTIVE_ARCH=NO
  SKIP_INSTALL=NO
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  DEVELOPMENT_TEAM=
)
if [[ -n "${LOCATION_SUITE_SOURCE_URL:-}" ]]; then
  xcodebuild_args+=("LOCATION_SUITE_SOURCE_URL=$LOCATION_SUITE_SOURCE_URL")
fi

set -o pipefail
xcodebuild "${xcodebuild_args[@]}" | tee "$build_log"

app_path="$archive_path/Products/Applications/TLocation.app"
info_plist="$app_path/Info.plist"
test -d "$app_path"
test -f "$info_plist"
plutil -lint "$info_plist"

plist_buddy=/usr/libexec/PlistBuddy
executable_name="$($plist_buddy -c 'Print :CFBundleExecutable' "$info_plist")"
bundle_identifier="$($plist_buddy -c 'Print :CFBundleIdentifier' "$info_plist")"
display_name="$($plist_buddy -c 'Print :CFBundleDisplayName' "$info_plist")"
version="$($plist_buddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_version="$($plist_buddy -c 'Print :CFBundleVersion' "$info_plist")"
minimum_os="$($plist_buddy -c 'Print :MinimumOSVersion' "$info_plist")"
executable_path="$app_path/$executable_name"

test "$bundle_identifier" = "$expected_bundle_id"
test "$display_name" = "$expected_display_name"
test "$minimum_os" = "$expected_minimum_os"
test -n "$version"
test -n "$build_version"
test -x "$executable_path"

case " $(lipo -archs "$executable_path") " in
  *" arm64 "*) ;;
  *) echo "The app executable lacks the required arm64 device slice." >&2; exit 1 ;;
esac

if codesign -d "$app_path" >/dev/null 2>&1; then
  echo "The canonical app unexpectedly contains a code signature." >&2
  exit 1
fi
if find "$app_path" -name embedded.mobileprovision -print -quit | grep -q .; then
  echo "The canonical app unexpectedly contains a provisioning profile." >&2
  exit 1
fi

mkdir -p "$staging_path/Payload" "$verification_path"
ditto "$app_path" "$staging_path/Payload/TLocation.app"
rm -f -- "$ipa_path"
(
  cd "$staging_path"
  zip -qry "$ipa_path" Payload
)

unzip -tq "$ipa_path"
unzip -q "$ipa_path" -d "$verification_path"
app_count="$(find "$verification_path/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
test "$app_count" = "1"
test -f "$verification_path/Payload/TLocation.app/Info.plist"

ipa_size="$(stat -f '%z' "$ipa_path")"
ipa_sha256="$(shasum -a 256 "$ipa_path" | awk '{print $1}')"
commit_sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"
release_timestamp="${RELEASE_TIMESTAMP:-$(git show -s --format=%cI "$commit_sha")}"
xcode_version="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
ios_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
executable_architectures="$(lipo -archs "$executable_path")"

export LS_BUILD_METADATA_PATH="$metadata_path"
export LS_BUNDLE_IDENTIFIER="$bundle_identifier"
export LS_DISPLAY_NAME="$display_name"
export LS_VERSION="$version"
export LS_BUILD_VERSION="$build_version"
export LS_MINIMUM_OS="$minimum_os"
export LS_IPA_NAME="$ipa_name"
export LS_IPA_SIZE="$ipa_size"
export LS_IPA_SHA256="$ipa_sha256"
export LS_COMMIT_SHA="$commit_sha"
export LS_RELEASE_TIMESTAMP="$release_timestamp"
export LS_XCODE_VERSION="$xcode_version"
export LS_IOS_SDK_VERSION="$ios_sdk_version"
export LS_EXECUTABLE_ARCHITECTURES="$executable_architectures"
python3 - <<'PY'
import json
import os
from pathlib import Path

metadata = {
    "schemaVersion": 1,
    "bundleIdentifier": os.environ["LS_BUNDLE_IDENTIFIER"],
    "displayName": os.environ["LS_DISPLAY_NAME"],
    "version": os.environ["LS_VERSION"],
    "buildVersion": os.environ["LS_BUILD_VERSION"],
    "minimumOSVersion": os.environ["LS_MINIMUM_OS"],
    "ipaFilename": os.environ["LS_IPA_NAME"],
    "ipaSize": int(os.environ["LS_IPA_SIZE"]),
    "ipaSHA256": os.environ["LS_IPA_SHA256"],
    "commitSHA": os.environ["LS_COMMIT_SHA"],
    "releaseTimestamp": os.environ["LS_RELEASE_TIMESTAMP"],
    "xcodeVersion": os.environ["LS_XCODE_VERSION"],
    "iOSSDKVersion": os.environ["LS_IOS_SDK_VERSION"],
    "executableArchitectures": os.environ["LS_EXECUTABLE_ARCHITECTURES"].split(),
    "signing": "unsigned",
}
Path(os.environ["LS_BUILD_METADATA_PATH"]).write_text(
    json.dumps(metadata, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "Unsigned IPA: $ipa_path"
echo "Version/build: $version ($build_version)"
echo "IPA size: $ipa_size bytes"
echo "IPA SHA-256: $ipa_sha256"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "ipa_path=$ipa_path"
    echo "metadata_path=$metadata_path"
    echo "version=$version"
    echo "build_version=$build_version"
    echo "ipa_size=$ipa_size"
    echo "ipa_sha256=$ipa_sha256"
  } >> "$GITHUB_OUTPUT"
fi
