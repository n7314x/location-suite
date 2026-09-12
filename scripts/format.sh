#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "Formatting Location Suite..."

# Normalize whitespace on tracked source/config/documentation files.
python3 - <<'PY'
from pathlib import Path
import subprocess

extensions = {
    ".swift",
    ".rs",
    ".h",
    ".c",
    ".cpp",
    ".m",
    ".mm",
    ".sh",
    ".py",
    ".js",
    ".jsx",
    ".ts",
    ".tsx",
    ".json",
    ".yml",
    ".yaml",
    ".md",
    ".toml",
    ".plist",
    ".xcconfig",
}

filenames = {
    "Makefile",
    "Dockerfile",
}

tracked = subprocess.check_output(
    ["git", "ls-files", "-z"]
).decode().split("\0")

changed = 0

for name in tracked:
    if not name:
        continue

    path = Path(name)

    if path.suffix.lower() not in extensions and path.name not in filenames:
        continue

    if not path.is_file():
        continue

    try:
        original = path.read_text()
    except UnicodeDecodeError:
        continue

    # Remove trailing spaces/tabs and guarantee exactly one final newline.
    lines = [line.rstrip() for line in original.splitlines()]
    formatted = "\n".join(lines) + "\n"

    if formatted != original:
        path.write_text(formatted)
        changed += 1
        print(f"  whitespace: {path}")

print(f"Whitespace-normalized files: {changed}")
PY

# Rust
if command -v cargo >/dev/null 2>&1; then
    if [[ -f ios/SelfMaintenanceCore/Cargo.toml ]]; then
        echo "Running rustfmt..."
        cargo fmt --manifest-path ios/SelfMaintenanceCore/Cargo.toml
    fi
else
    echo "Skipping rustfmt: cargo is not installed."
fi

# Swift
if command -v swift-format >/dev/null 2>&1; then
    echo "Running swift-format..."
    find ios/TLocation ios/TLocationTests \
        -type f -name '*.swift' \
        -print0 2>/dev/null \
        | xargs -0 swift-format format --in-place
elif command -v xcrun >/dev/null 2>&1 && xcrun --find swift-format >/dev/null 2>&1; then
    echo "Running swift-format through Xcode..."
    find ios/TLocation ios/TLocationTests \
        -type f -name '*.swift' \
        -print0 2>/dev/null \
        | xargs -0 xcrun swift-format format --in-place
else
    echo "Skipping swift-format: swift-format is not installed."
fi

echo
echo "Checking Git whitespace..."
git diff --check

echo
echo "Formatter finished."
