#!/usr/bin/env python3
"""Verify an IPA, release metadata, and AltStore Classic source agree exactly."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

from release_feed import (
    BUNDLE_ID,
    IPA_NAME,
    ReleaseError,
    read_ipa_metadata,
    read_json,
    source_app,
    validate_https_base_url,
    validate_release_date,
    validate_source_shape,
)

LOCAL_PATH_PATTERN = re.compile(r"(?:/Users/|/home/|/private/var/|[A-Za-z]:\\\\)")


def assert_no_local_paths(value: Any) -> None:
    serialized = json.dumps(value, ensure_ascii=False)
    if LOCAL_PATH_PATTERN.search(serialized):
        raise ReleaseError("Release JSON leaks an absolute local filesystem path")


def verify_files(
    ipa_path: Path,
    metadata_path: Path,
    source_path: Path,
    previous_source_path: Path | None = None,
) -> dict[str, Any]:
    ipa = read_ipa_metadata(ipa_path)
    metadata = read_json(metadata_path)
    source = read_json(source_path)
    validate_source_shape(source)
    assert_no_local_paths(metadata)
    assert_no_local_paths(source)

    expected = {
        "bundleIdentifier": ipa.bundle_identifier,
        "version": ipa.version,
        "buildVersion": ipa.build_version,
        "size": ipa.size,
        "sha256": ipa.sha256,
        "minOSVersion": ipa.minimum_os_version,
        "signing": "unsigned",
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            raise ReleaseError(f"Release metadata {key} mismatch: {metadata.get(key)!r} != {value!r}")
    if ipa.bundle_identifier != BUNDLE_ID:
        raise ReleaseError(f"Wrong IPA bundle identifier: {ipa.bundle_identifier}")
    validate_release_date(str(metadata.get("releaseDate", "")))
    download_url = str(metadata.get("downloadURL", ""))
    validate_https_base_url(download_url)
    if not download_url.endswith(f"/v{ipa.version}/{IPA_NAME}"):
        raise ReleaseError("Release download URL is not the immutable versioned IPA URL")

    versions = source_app(source)["versions"]
    matches = [
        version
        for version in versions
        if version["version"] == ipa.version and str(version["buildVersion"]) == ipa.build_version
    ]
    if len(matches) != 1:
        raise ReleaseError("Source does not contain exactly one matching version/build entry")
    entry = matches[0]
    entry_expected = {
        "date": metadata["releaseDate"],
        "downloadURL": download_url,
        "size": ipa.size,
        "minOSVersion": ipa.minimum_os_version,
    }
    for key, value in entry_expected.items():
        if entry.get(key) != value:
            raise ReleaseError(f"Source {key} mismatch: {entry.get(key)!r} != {value!r}")
    if versions[0] != entry:
        raise ReleaseError("The generated release is not the source's latest stable entry")

    if previous_source_path:
        previous = read_json(previous_source_path)
        validate_source_shape(previous)
        if any(
            version["version"] == ipa.version
            or (
                version["version"] == ipa.version
                and str(version["buildVersion"]) == ipa.build_version
            )
            for version in source_app(previous)["versions"]
        ):
            raise ReleaseError("The release version/build was already present in the production source")
    return metadata


def verify_remote(source_url: str, timeout: float) -> None:
    validate_https_base_url(source_url)
    with urllib.request.urlopen(source_url, timeout=timeout) as response:
        source_bytes = response.read()
    source = json.loads(source_bytes)
    validate_source_shape(source)
    latest = source_app(source)["versions"][0]
    download_url = latest["downloadURL"]
    with urllib.request.urlopen(download_url, timeout=timeout) as response:
        ipa_bytes = response.read()
    expected_size = latest["size"]
    if len(ipa_bytes) != expected_size:
        raise ReleaseError(f"Published IPA size mismatch: {len(ipa_bytes)} != {expected_size}")

    metadata_url = download_url.rsplit("/", 1)[0] + "/release-metadata.json"
    with urllib.request.urlopen(metadata_url, timeout=timeout) as response:
        metadata = json.loads(response.read())
    actual_hash = hashlib.sha256(ipa_bytes).hexdigest()
    if metadata.get("sha256") != actual_hash:
        raise ReleaseError("Published IPA SHA-256 does not match release metadata")
    if metadata.get("version") != latest["version"] or str(metadata.get("buildVersion")) != str(
        latest["buildVersion"]
    ):
        raise ReleaseError("Published latest source entry and release metadata disagree")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path)
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--previous-source", type=Path)
    parser.add_argument("--remote-source-url")
    parser.add_argument("--timeout", type=float, default=15)
    args = parser.parse_args()
    try:
        if args.remote_source_url:
            verify_remote(args.remote_source_url, args.timeout)
        else:
            if not (args.ipa and args.metadata and args.source):
                parser.error("local verification requires --ipa, --metadata, and --source")
            verify_files(args.ipa, args.metadata, args.source, args.previous_source)
    except (ReleaseError, OSError, ValueError, json.JSONDecodeError) as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        return 1
    print("Release verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
