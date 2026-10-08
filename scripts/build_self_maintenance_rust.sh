#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
crate_dir="$project_root/ios/SelfMaintenanceCore"
output_dir="$project_root/ios/TLocation/self_maintenance"
target="${RUST_IOS_TARGET:-aarch64-apple-ios}"
profile="${RUST_PROFILE:-release}"

command -v cargo >/dev/null || {
  echo "Rust/cargo is required to build the self-maintenance core." >&2
  exit 2
}

mkdir -p "$output_dir"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.4}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$project_root=/src/location-suite"

cargo build \
  --locked \
  --manifest-path "$crate_dir/Cargo.toml" \
  --profile "$profile" \
  --target "$target"

install -m 0644 \
  "$crate_dir/target/$target/$profile/liblocation_self_maintenance.a" \
  "$output_dir/liblocation_self_maintenance.a"
install -m 0644 "$crate_dir/include/location_self_maintenance.h" "$output_dir/location_self_maintenance.h"
install -m 0644 "$crate_dir/include/module.modulemap" "$output_dir/module.modulemap"

echo "Self-maintenance Rust core: $output_dir/liblocation_self_maintenance.a"
