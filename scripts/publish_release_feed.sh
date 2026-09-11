#!/usr/bin/env bash
set -euo pipefail

generated_root="${1:?usage: publish_release_feed.sh GENERATED_ROOT PUBLIC_REPOSITORY_CHECKOUT}"
public_checkout="${2:?usage: publish_release_feed.sh GENERATED_ROOT PUBLIC_REPOSITORY_CHECKOUT}"

test -d "$generated_root"
test -d "$public_checkout/.git"
test -f "$generated_root/source-staging.json"

version_dir="$(find "$generated_root" -mindepth 1 -maxdepth 1 -type d -name 'v*' -print -quit)"
test -n "$version_dir"
version_name="$(basename "$version_dir")"
destination="$public_checkout/$version_name"

if [[ -e "$destination" ]]; then
  echo "Refusing to overwrite published immutable release $destination" >&2
  exit 1
fi

cp -R "$version_dir" "$destination"
mkdir -p "$public_checkout/assets"
cp "$generated_root/assets/tlocation-icon.png" "$public_checkout/assets/tlocation-icon.png"
cp "$generated_root/source-staging.json" "$public_checkout/source-staging.json"

# Promotion is deliberately a separate validated operation, even though both
# files are committed atomically to avoid exposing a half-published release.
python3 scripts/release_feed.py promote \
  --staging-source "$public_checkout/source-staging.json" \
  --output "$public_checkout/source.json"

(
  cd "$public_checkout"
  git add "$version_name" assets/tlocation-icon.png source-staging.json source.json
  git diff --cached --check
  git commit -m "Publish Location Suite $version_name"
  git push origin HEAD:main
)
