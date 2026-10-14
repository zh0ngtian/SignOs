"""Exercise the artifact checks that gate public GitHub Releases."""

import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import sys
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "prepare_github_release.py"
sys.path.insert(0, str(SCRIPT.parent))
SPEC = importlib.util.spec_from_file_location("prepare_github_release", SCRIPT)
RELEASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELEASE)


class GitHubReleaseRegression(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.commit = "a" * 40
        self.info = {
            "CFBundleIdentifier": "com.signos.app",
            "CFBundleShortVersionString": "1.0.11",
            "CFBundleVersion": "12",
            "MinimumOSVersion": "15.0",
        }
        self.write_artifacts()

    def write_artifacts(self, private_resource=None):
        ipa = self.output / "SignOs.ipa"
        with zipfile.ZipFile(ipa, "w") as archive:
            archive.writestr("Payload/SignOs.app/Info.plist", plistlib.dumps(self.info))
            if private_resource:
                archive.writestr(f"Payload/SignOs.app/{private_resource}", "fixture")
        self.metadata = {
            "commit": self.commit,
            "bundleIdentifier": "com.signos.app",
            "version": "1.0.11",
            "buildNumber": "12",
            "minimumOSVersion": "15.0",
            "distributionSigned": False,
            "size": ipa.stat().st_size,
            "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(),
        }
        notes = {"schemaVersion": 1, "batchId": "11111111-1111-1111-1111-111111111111",
                 "language": "zh-Hans", "version": "1.0.11", "buildNumber": "12",
                 "tasks": [{"id": "task", "sha": "c" * 40, "changes": ["修复更新日志缺失时仍允许发布的问题"]}]}
        manifest = {"batchId": notes["batchId"], "scope": "test", "tasks": notes["tasks"],
                    "prepared": {"version": "1.0.11", "buildNumber": "12"}}
        (self.output / "release-notes.json").write_text(json.dumps(notes))
        (self.output / "release-batch.json").write_text(json.dumps(manifest))
        self.metadata.update({
            "batchId": notes["batchId"], "releaseScope": "test",
            "batchManifestSha256": hashlib.sha256((self.output / "release-batch.json").read_bytes()).hexdigest(),
            "releaseNotesSha256": hashlib.sha256((self.output / "release-notes.json").read_bytes()).hexdigest(),
        })
        self.write_metadata()

    def write_metadata(self):
        (self.output / "build-metadata.json").write_text(json.dumps(self.metadata))

    def prepare(self, tag="v1.0.11", commit=None):
        RELEASE.prepare_release(self.output, tag, commit or self.commit)

    def test_valid_release_includes_verifiable_checksums_and_installation_notes(self):
        self.prepare()
        for line in (self.output / "SHA256SUMS").read_text().splitlines():
            digest, filename = line.split("  ")
            self.assertEqual(digest, hashlib.sha256((self.output / filename).read_bytes()).hexdigest())
        notes = (self.output / "release-notes.md").read_text()
        self.assertIn("1.0.11（构建 12）", notes)
        self.assertIn("安装前需要使用签名工具签名", notes)
        self.assertIn(self.commit, notes)

    def test_rejects_invalid_or_mismatched_tags(self):
        for tag in ("1.0.11", "v1.0.11-beta", "v01.0.11", "v1.0.12"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                self.prepare(tag)

    def test_rejects_artifacts_from_another_commit(self):
        with self.assertRaisesRegex(ValueError, "commit"):
            self.prepare(commit="b" * 40)

    def test_rejects_tampered_ipa(self):
        with (self.output / "SignOs.ipa").open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum or size"):
            self.prepare()

    def test_rejects_inconsistent_package_identity(self):
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            with self.subTest(key=key):
                original = self.info[key]
                self.info[key] = "unexpected"
                self.write_artifacts()
                with self.assertRaisesRegex(ValueError, key):
                    self.prepare()
                self.info[key] = original

    def test_rejects_private_distribution_resources(self):
        for resource in ("server.crt", "server.pem", "commonName.txt", "embedded.mobileprovision"):
            with self.subTest(resource=resource):
                self.write_artifacts(resource)
                with self.assertRaisesRegex(ValueError, "private distribution resource"):
                    self.prepare()

    def test_rejects_distribution_signed_metadata(self):
        self.metadata["distributionSigned"] = True
        self.write_metadata()
        with self.assertRaisesRegex(ValueError, "distribution signing"):
            self.prepare()


if __name__ == "__main__":
    unittest.main()
