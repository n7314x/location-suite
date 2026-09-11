from __future__ import annotations

import argparse
import json
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

import sys

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from release_feed import (  # noqa: E402
    BUNDLE_ID,
    ReleaseError,
    generate,
    promote,
    read_json,
    validate_source_shape,
)
from verify_release import verify_files  # noqa: E402


class ReleaseToolTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.icon = self.root / "icon.png"
        self.icon.write_bytes(b"test-icon")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_ipa(
        self,
        *,
        name: str = "build.ipa",
        bundle_id: str = BUNDLE_ID,
        version: str = "1.5.0",
        build_version: str = "15",
        minimum_os: str = "17.4",
    ) -> Path:
        ipa = self.root / name
        info = {
            "CFBundleIdentifier": bundle_id,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build_version,
            "MinimumOSVersion": minimum_os,
        }
        with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("Payload/TLocation.app/Info.plist", plistlib.dumps(info))
            archive.writestr("Payload/TLocation.app/TLocation", b"arm64-placeholder")
        return ipa

    def generate_release(
        self,
        ipa: Path | None = None,
        *,
        output_name: str = "generated",
        existing_source: Path | None = None,
    ) -> Path:
        ipa = ipa or self.make_ipa()
        output = self.root / output_name
        generate(
            argparse.Namespace(
                ipa=ipa,
                output_root=output,
                base_url="https://releases.example.test/location-suite",
                release_date="2026-09-10T12:00:00-04:00",
                commit_sha="a" * 40,
                xcode_version="Xcode 27.0 Build version 18A1",
                ios_sdk_version="27.0",
                notes="Release notes",
                expected_version=None,
                expected_build=None,
                existing_source=existing_source,
                icon=self.icon,
            )
        )
        return output

    def test_source_generator_produces_current_classic_shape(self) -> None:
        output = self.generate_release()
        source = read_json(output / "source-staging.json")
        validate_source_shape(source)
        version = source["apps"][0]["versions"][0]
        self.assertEqual(version["version"], "1.5.0")
        self.assertEqual(version["buildVersion"], "15")
        self.assertNotIn("sha256", version)  # Not part of the current AltSource schema.
        self.assertIn("appPermissions", source["apps"][0])

    def test_built_ipa_metadata_equals_feed_metadata(self) -> None:
        ipa = self.make_ipa()
        output = self.generate_release(ipa)
        metadata = verify_files(
            output / "v1.5.0/LocationSuite.ipa",
            output / "v1.5.0/release-metadata.json",
            output / "source-staging.json",
        )
        self.assertEqual(metadata["version"], "1.5.0")
        self.assertEqual(metadata["buildVersion"], "15")

    def test_wrong_sha_fails(self) -> None:
        output = self.generate_release()
        metadata_path = output / "v1.5.0/release-metadata.json"
        metadata = read_json(metadata_path)
        metadata["sha256"] = "0" * 64
        metadata_path.write_text(json.dumps(metadata), encoding="utf-8")
        with self.assertRaisesRegex(ReleaseError, "sha256 mismatch"):
            verify_files(
                output / "v1.5.0/LocationSuite.ipa",
                metadata_path,
                output / "source-staging.json",
            )

    def test_wrong_bundle_identifier_fails(self) -> None:
        with self.assertRaisesRegex(ReleaseError, "Wrong built bundle identifier"):
            self.generate_release(self.make_ipa(bundle_id="example.wrong"))

    def test_wrong_version_fails(self) -> None:
        ipa = self.make_ipa()
        with self.assertRaisesRegex(ReleaseError, "does not match expected"):
            generate(
                argparse.Namespace(
                    ipa=ipa,
                    output_root=self.root / "wrong-version",
                    base_url="https://releases.example.test/location-suite",
                    release_date="2026-09-10T12:00:00-04:00",
                    commit_sha="a" * 40,
                    xcode_version="Xcode 27",
                    ios_sdk_version="27.0",
                    notes="",
                    expected_version="1.5.1",
                    expected_build=None,
                    existing_source=None,
                    icon=self.icon,
                )
            )

    def test_duplicate_version_build_fails(self) -> None:
        first = self.generate_release(output_name="first")
        with self.assertRaisesRegex(ReleaseError, "already published"):
            self.generate_release(
                output_name="duplicate",
                existing_source=first / "source-staging.json",
            )

    def test_build_version_must_increase_monotonically(self) -> None:
        first_ipa = self.make_ipa(name="first-build.ipa", version="1.5.0", build_version="15")
        first = self.generate_release(first_ipa, output_name="first-build")
        lower_ipa = self.make_ipa(name="lower-build.ipa", version="1.5.1", build_version="14")
        with self.assertRaisesRegex(ReleaseError, "not greater"):
            self.generate_release(
                lower_ipa,
                output_name="lower-build",
                existing_source=first / "source-staging.json",
            )

    def test_staging_promotion_preserves_immutable_history(self) -> None:
        first = self.generate_release(output_name="first")
        second_ipa = self.make_ipa(name="second.ipa", version="1.5.1", build_version="16")
        second = self.generate_release(
            second_ipa,
            output_name="second",
            existing_source=first / "source-staging.json",
        )
        production = self.root / "source.json"
        promote(
            argparse.Namespace(
                staging_source=second / "source-staging.json",
                output=production,
            )
        )
        versions = read_json(production)["apps"][0]["versions"]
        self.assertEqual(
            [(item["version"], item["buildVersion"]) for item in versions],
            [("1.5.1", "16"), ("1.5.0", "15")],
        )
        self.assertTrue((first / "v1.5.0/LocationSuite.ipa").exists())

    def test_ipa_with_extra_top_level_content_fails(self) -> None:
        ipa = self.make_ipa()
        with zipfile.ZipFile(ipa, "a") as archive:
            archive.writestr("secret.txt", b"unexpected")
        with self.assertRaisesRegex(ReleaseError, "only Payload"):
            self.generate_release(ipa)


if __name__ == "__main__":
    unittest.main()
