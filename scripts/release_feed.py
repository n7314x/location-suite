#!/usr/bin/env python3
"""Generate and promote immutable Location Suite AltStore Classic releases."""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import plistlib
import re
import shutil
import sys
import urllib.parse
import zipfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

BUNDLE_ID = "vn.truongkma.tlocation"
SOURCE_ID = "vn.truongkma.locationsuite.source"
IPA_NAME = "LocationSuite.ipa"
SEMVER = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:[-+][0-9A-Za-z.-]+)?$")


class ReleaseError(ValueError):
    pass


@dataclass(frozen=True)
class IPAMetadata:
    bundle_identifier: str
    version: str
    build_version: str
    minimum_os_version: str
    size: int
    sha256: str


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseError(f"Could not read JSON {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"Expected a JSON object in {path}")
    return value


def write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def read_ipa_metadata(ipa_path: Path) -> IPAMetadata:
    try:
        with zipfile.ZipFile(ipa_path) as archive:
            bad_member = archive.testzip()
            if bad_member:
                raise ReleaseError(f"IPA CRC validation failed at {bad_member}")

            names = archive.namelist()
            if any(name.startswith("/") or ".." in Path(name).parts for name in names):
                raise ReleaseError("IPA contains an unsafe absolute or parent-relative path")
            top_levels = {name.split("/", 1)[0] for name in names if name}
            if top_levels != {"Payload"}:
                raise ReleaseError(f"IPA must contain only Payload at top level, found {sorted(top_levels)}")

            app_roots = {
                "/".join(parts[:2])
                for name in names
                if len(parts := name.rstrip("/").split("/")) >= 2
                and parts[0] == "Payload"
                and parts[1].endswith(".app")
            }
            if app_roots != {"Payload/TLocation.app"}:
                raise ReleaseError(
                    "IPA must contain exactly Payload/TLocation.app; "
                    f"found {sorted(app_roots)}"
                )
            info_name = "Payload/TLocation.app/Info.plist"
            if info_name not in names:
                raise ReleaseError("IPA is missing Payload/TLocation.app/Info.plist")
            info = plistlib.loads(archive.read(info_name))
    except (OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        raise ReleaseError(f"Invalid IPA {ipa_path}: {error}") from error

    required = {
        "CFBundleIdentifier": str,
        "CFBundleShortVersionString": str,
        "CFBundleVersion": str,
        "MinimumOSVersion": str,
    }
    for key, expected_type in required.items():
        if not isinstance(info.get(key), expected_type) or not info[key]:
            raise ReleaseError(f"Built app has no valid {key}")

    digest = hashlib.sha256(ipa_path.read_bytes()).hexdigest()
    return IPAMetadata(
        bundle_identifier=info["CFBundleIdentifier"],
        version=info["CFBundleShortVersionString"],
        build_version=info["CFBundleVersion"],
        minimum_os_version=info["MinimumOSVersion"],
        size=ipa_path.stat().st_size,
        sha256=digest,
    )


def validate_https_base_url(raw_url: str) -> str:
    parsed = urllib.parse.urlsplit(raw_url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
        raise ReleaseError("Release base URL must be an absolute HTTPS URL without query or fragment")
    return raw_url.rstrip("/")


def validate_release_date(value: str) -> str:
    normalized = value.replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ReleaseError(f"Release date is not ISO 8601: {value}") from error
    if parsed.tzinfo is None:
        raise ReleaseError("Release date must include a time-zone offset")
    return value


def empty_source(base_url: str) -> dict[str, Any]:
    return {
        "name": "Location Suite",
        "identifier": SOURCE_ID,
        "subtitle": "Unsigned iOS releases for local signing with SideStore",
        "website": base_url,
        "tintColor": "#2677F3",
        "apps": [
            {
                "name": "Location Suite",
                "bundleIdentifier": BUNDLE_ID,
                "developerName": "n7314x",
                "subtitle": "System-wide location simulation",
                "localizedDescription": (
                    "Location Suite simulates the device location through Apple's "
                    "developer LocationSimulation service. SideStore signs this canonical "
                    "unsigned build locally with the user's Apple Account."
                ),
                "iconURL": f"{base_url}/assets/tlocation-icon.png",
                "tintColor": "#2677F3",
                "category": "utilities",
                "versions": [],
                "appPermissions": {
                    "entitlements": [
                        "com.apple.security.app-sandbox",
                        "com.apple.security.files.user-selected.read-only",
                    ],
                    "privacy": {
                        "NSLocalNetworkUsageDescription": (
                            "Location Suite needs access to devices on your local network to "
                            "connect to this device and simulate its location."
                        ),
                        "NSLocationAlwaysAndWhenInUseUsageDescription": (
                            "Location Suite uses your location to center the map on your position "
                            "and to keep location simulation running in the background."
                        ),
                        "NSLocationWhenInUseUsageDescription": (
                            "Location Suite uses your location to center the map on your position "
                            "and to keep location simulation running in the background."
                        ),
                    },
                },
            }
        ],
        "news": [],
    }


def source_app(source: dict[str, Any]) -> dict[str, Any]:
    apps = source.get("apps")
    if not isinstance(apps, list):
        raise ReleaseError("Source apps must be an array")
    matches = [app for app in apps if isinstance(app, dict) and app.get("bundleIdentifier") == BUNDLE_ID]
    if len(matches) != 1:
        raise ReleaseError(f"Source must contain exactly one {BUNDLE_ID} app")
    return matches[0]


def validate_source_shape(source: dict[str, Any]) -> None:
    if source.get("name") != "Location Suite" or source.get("identifier") != SOURCE_ID:
        raise ReleaseError("Unexpected Location Suite source identity")
    app = source_app(source)
    required_app_keys = (
        "name",
        "bundleIdentifier",
        "developerName",
        "localizedDescription",
        "iconURL",
        "versions",
        "appPermissions",
    )
    for key in required_app_keys:
        if key not in app:
            raise ReleaseError(f"Source app is missing {key}")
    if not isinstance(app["versions"], list):
        raise ReleaseError("Source versions must be an array")

    seen_pairs: set[tuple[str, str]] = set()
    seen_versions: set[str] = set()
    for version in app["versions"]:
        if not isinstance(version, dict):
            raise ReleaseError("Every source version must be an object")
        for key in ("version", "buildVersion", "date", "downloadURL", "size", "minOSVersion"):
            if key not in version:
                raise ReleaseError(f"Source version is missing {key}")
        pair = (str(version["version"]), str(version["buildVersion"]))
        if pair in seen_pairs:
            raise ReleaseError(f"Duplicate source version/build pair: {pair[0]} ({pair[1]})")
        if pair[0] in seen_versions:
            raise ReleaseError(f"Duplicate immutable version path would be required for {pair[0]}")
        seen_pairs.add(pair)
        seen_versions.add(pair[0])
        validate_release_date(str(version["date"]))
        validate_https_base_url(str(version["downloadURL"]))
        if not isinstance(version["size"], int) or version["size"] <= 0:
            raise ReleaseError("Source version size must be a positive integer")


def build_version_components(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ReleaseError(
            f"Build version must be one to three dot-separated nonnegative integers: {value}"
        )
    return tuple(int(component) for component in value.split("."))


def make_release_metadata(
    ipa: IPAMetadata,
    *,
    base_url: str,
    release_date: str,
    commit_sha: str,
    xcode_version: str,
    ios_sdk_version: str,
    notes: str,
) -> dict[str, Any]:
    download_url = f"{base_url}/v{ipa.version}/{IPA_NAME}"
    return {
        "schemaVersion": 1,
        "name": "Location Suite",
        "bundleIdentifier": ipa.bundle_identifier,
        "version": ipa.version,
        "buildVersion": ipa.build_version,
        "releaseDate": release_date,
        "releaseNotes": notes,
        "downloadURL": download_url,
        "size": ipa.size,
        "sha256": ipa.sha256,
        "minOSVersion": ipa.minimum_os_version,
        "commitSHA": commit_sha,
        "xcodeVersion": xcode_version,
        "iOSSDKVersion": ios_sdk_version,
        "signing": "unsigned",
    }


def make_version_entry(metadata: dict[str, Any]) -> dict[str, Any]:
    result: dict[str, Any] = {
        "version": metadata["version"],
        "buildVersion": metadata["buildVersion"],
        "date": metadata["releaseDate"],
        "downloadURL": metadata["downloadURL"],
        "size": metadata["size"],
        "minOSVersion": metadata["minOSVersion"],
    }
    if metadata.get("releaseNotes"):
        result["localizedDescription"] = metadata["releaseNotes"]
    return result


def generate(args: argparse.Namespace) -> None:
    ipa_path = args.ipa.resolve()
    output_root = args.output_root.resolve()
    ipa = read_ipa_metadata(ipa_path)
    if ipa.bundle_identifier != BUNDLE_ID:
        raise ReleaseError(f"Wrong built bundle identifier: {ipa.bundle_identifier}")
    if not SEMVER.fullmatch(ipa.version):
        raise ReleaseError(f"Built marketing version is not a supported semantic version: {ipa.version}")
    if args.expected_version and ipa.version != args.expected_version:
        raise ReleaseError(f"Built version {ipa.version} does not match expected {args.expected_version}")
    if args.expected_build and ipa.build_version != args.expected_build:
        raise ReleaseError(
            f"Built build number {ipa.build_version} does not match expected {args.expected_build}"
        )

    base_url = validate_https_base_url(args.base_url)
    release_date = validate_release_date(args.release_date)
    notes = args.notes.strip()
    source = read_json(args.existing_source) if args.existing_source else empty_source(base_url)
    validate_source_shape(source)
    source = copy.deepcopy(source)
    app = source_app(source)
    if any(version["version"] == ipa.version for version in app["versions"]):
        raise ReleaseError(f"Version {ipa.version} is already published; immutable output will not be overwritten")
    if any(
        version["version"] == ipa.version and str(version["buildVersion"]) == ipa.build_version
        for version in app["versions"]
    ):
        raise ReleaseError(f"Version/build {ipa.version} ({ipa.build_version}) is already published")
    new_build = build_version_components(ipa.build_version)
    existing_builds = [build_version_components(str(version["buildVersion"])) for version in app["versions"]]
    if existing_builds and new_build <= max(existing_builds):
        raise ReleaseError(
            f"Build version {ipa.build_version} is not greater than the published build versions"
        )

    canonical = empty_source(base_url)
    canonical_app = source_app(canonical)
    # Preserve only immutable version history; refresh descriptive and permission
    # metadata from the generator so stale upstream fields cannot survive.
    canonical_app["versions"] = copy.deepcopy(app["versions"])
    source = canonical
    app = source_app(source)

    metadata = make_release_metadata(
        ipa,
        base_url=base_url,
        release_date=release_date,
        commit_sha=args.commit_sha,
        xcode_version=args.xcode_version,
        ios_sdk_version=args.ios_sdk_version,
        notes=notes,
    )
    app["versions"].insert(0, make_version_entry(metadata))
    validate_source_shape(source)

    version_dir = output_root / f"v{ipa.version}"
    if version_dir.exists() and any(version_dir.iterdir()):
        raise ReleaseError(f"Refusing to overwrite existing immutable directory {version_dir}")
    version_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(ipa_path, version_dir / IPA_NAME)
    write_json(version_dir / "release-metadata.json", metadata)
    (version_dir / "SHA256SUMS").write_text(f"{ipa.sha256}  {IPA_NAME}\n", encoding="utf-8")
    write_json(output_root / "source-staging.json", source)
    assets_dir = output_root / "assets"
    assets_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.icon, assets_dir / "tlocation-icon.png")


def promote(args: argparse.Namespace) -> None:
    source = read_json(args.staging_source)
    validate_source_shape(source)
    output = args.output.resolve()
    if output.exists() and output.read_bytes() == args.staging_source.read_bytes():
        return
    shutil.copyfile(args.staging_source, output)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    generate_parser = commands.add_parser("generate")
    generate_parser.add_argument("--ipa", type=Path, required=True)
    generate_parser.add_argument("--output-root", type=Path, required=True)
    generate_parser.add_argument("--base-url", required=True)
    generate_parser.add_argument("--release-date", required=True)
    generate_parser.add_argument("--commit-sha", required=True)
    generate_parser.add_argument("--xcode-version", required=True)
    generate_parser.add_argument("--ios-sdk-version", required=True)
    generate_parser.add_argument("--notes", default="")
    generate_parser.add_argument("--expected-version")
    generate_parser.add_argument("--expected-build")
    generate_parser.add_argument("--existing-source", type=Path)
    generate_parser.add_argument(
        "--icon", type=Path, default=Path("ios/assets/tlocation-icon.png")
    )
    generate_parser.set_defaults(handler=generate)

    promote_parser = commands.add_parser("promote")
    promote_parser.add_argument("--staging-source", type=Path, required=True)
    promote_parser.add_argument("--output", type=Path, required=True)
    promote_parser.set_defaults(handler=promote)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        args.handler(args)
    except ReleaseError as error:
        print(f"release-feed error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
