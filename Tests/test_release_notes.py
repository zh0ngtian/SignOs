"""Verify that Chinese changes gate publication and survive frozen artifact transport."""
import hashlib
import json
import shutil
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from signos_release_adapter import Adapter
from prepare_github_release import prepare_release
from release_notes import changelog

BATCH = "11111111-1111-1111-1111-111111111111"
CHANGE = "修复软件源禁用后缺少重新启用入口的问题"
OTHER = "新增软件源卡片长按启用与禁用操作"
MISSING = object()


class ChineseReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name) / "repo"
        self.root.mkdir()
        (self.root / "Feather.xcodeproj").mkdir()
        (self.root / "Feather.xcconfig").write_text("FEATHER_PROJECT_VERSION=1.1.13\n")
        (self.root / "Feather.xcodeproj/project.pbxproj").write_text("CURRENT_PROJECT_VERSION = 35;")
        self.artifacts = self.root.parent / "artifacts"
        self.artifacts.mkdir()
        self.commands = []

    def adapter(self, changes=MISSING, language="zh-Hans"):
        a = Adapter.__new__(Adapter)
        a.root = self.root
        a.artifacts = self.artifacts
        a.repository = "zh0ngtian/SignOs"
        a.config = {"outputRoot": str(self.root.parent / "output"), "baseUrl": "https://example.invalid"}
        a.options = {"ota_publisher": "/test/release_ipa.py"}
        a.private = Path("/test/config.json")
        validation = {"checks": [{"name": "unit", "status": "passed"}]}
        if changes is not MISSING:
            validation["releaseNotes"] = {"language": language, "changes": changes}
        a.data = {"id": BATCH, "tasks": [{"id": "task-a", "sha": "a" * 40, "validation": validation}],
                  "frozen": {"sha": "b" * 40, "version": "1.1.14", "buildNumber": "36"}}
        a.progress = lambda *args, **kwargs: None
        a.current = lambda: {"version": "1.1.13", "buildNumber": "35"}
        a.gh = lambda *args: [{"tagName": "v1.1.13", "isDraft": False}]
        def cmd(args):
            self.commands.append(args)
            if args == ["make", "iphoneos"]:
                v = (self.root / "Feather.xcconfig").read_text().split("=")[1].strip()
                info = {"CFBundleIdentifier": "com.signos.app",
                        "CFBundleShortVersionString": v, "CFBundleVersion": "36"}
                (self.root / "packages").mkdir(exist_ok=True)
                with zipfile.ZipFile(self.root / "packages/SignOs.ipa", "w") as z:
                    z.writestr("Payload/SignOs.app/Info.plist", plistlib.dumps(info))
            return "{}"
        a.cmd = cmd
        return a

    def freeze(self, a):
        record = {"schemaVersion": 1, "batchId": BATCH, "language": "zh-Hans",
                  "version": "1.1.14", "buildNumber": "36",
                  "tasks": [{"id": "task-a", "sha": "a" * 40, "changes": [CHANGE]}]}
        manifest = {"schemaVersion": 1, "batchId": BATCH, "project": "signos-production",
                    "scope": "test", "target": "com.signos.app", "environment": "production",
                    "tasks": [{"id": "task-a", "sha": "a" * 40,
                               "validation": {"checks": [{"name": "unit", "status": "passed"}]}}],
                    "prepared": {"version": "1.1.14", "buildNumber": "36"}}
        (self.root / ".release-batch.json").write_text(json.dumps(manifest))
        (self.root / ".release-notes.json").write_text(json.dumps(record, ensure_ascii=False))
        a.data["frozen"]["manifestSha256"] = hashlib.sha256(
            (self.root / ".release-batch.json").read_bytes()).hexdigest()
        return record, manifest

    def package(self, a):
        record, manifest = self.freeze(a)
        target = self.artifacts / "ci"
        if target.exists(): shutil.rmtree(target)
        target.mkdir()
        (target / "release-batch.json").write_text(json.dumps(manifest))
        (target / "release-notes.json").write_text(json.dumps(record, ensure_ascii=False))
        info = {"CFBundleIdentifier": "com.signos.app", "CFBundleShortVersionString": "1.1.14",
                "CFBundleVersion": "36", "MinimumOSVersion": "17.0"}
        ipa = target / "SignOs.ipa"
        with zipfile.ZipFile(ipa, "w") as z:
            z.writestr("Payload/SignOs.app/Info.plist", plistlib.dumps(info))
        meta = {"commit": "b" * 40, "version": "1.1.14", "buildNumber": "36",
                "bundleIdentifier": "com.signos.app", "minimumOSVersion": "17.0",
                "distributionSigned": False, "size": ipa.stat().st_size,
                "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest(), "batchId": BATCH,
                "batchManifestSha256": hashlib.sha256((target / "release-batch.json").read_bytes()).hexdigest(),
                "releaseScope": "test",
                "releaseNotesSha256": hashlib.sha256((target / "release-notes.json").read_bytes()).hexdigest()}
        (target / "build-metadata.json").write_text(json.dumps(meta))
        return target, meta

    def test_missing_english_or_placeholder_notes_stop_before_version_allocation_and_build(self):
        for changes, language in [(MISSING, "zh-Hans"), ([], "zh-Hans"),
                                  (["Improve source management"], "zh-Hans"),
                                  (["修复已知问题"], "zh-Hans"), (["TODO"], "zh-Hans"),
                                  ([CHANGE], "en"), ("更新软件源管理入口", "zh-Hans")]:
            with self.subTest(changes=changes, language=language):
                self.commands.clear()
                shutil.rmtree(self.artifacts); self.artifacts.mkdir()
                (self.root / "Feather.xcconfig").write_text("FEATHER_PROJECT_VERSION=1.1.13\n")
                (self.root / "Feather.xcodeproj/project.pbxproj").write_text("CURRENT_PROJECT_VERSION = 35;")
                a = self.adapter(changes, language)
                before = (self.root / "Feather.xcconfig").read_bytes()
                with patch("signos_release_adapter.fingerprint", return_value="stable"):
                    with self.assertRaisesRegex(ValueError, "中文更新日志"):
                        a.prepare()
                self.assertEqual(self.commands, [])
                self.assertFalse((self.artifacts / "prepared.json").exists())
                self.assertEqual((self.root / "Feather.xcconfig").read_bytes(), before)

    def test_multiple_tasks_freeze_their_notes_and_deduplicate_shared_changes(self):
        a = self.adapter([CHANGE])
        a.data["tasks"].append({"id": "task-b", "sha": "c" * 40,
                                "validation": {"checks": [{"status": "passed"}],
                                               "releaseNotes": {"language": "zh-Hans", "changes": [CHANGE, OTHER]}}})
        with patch("signos_release_adapter.fingerprint", return_value="stable"):
            result = a.prepare()
        self.assertTrue(result["done"])
        self.assertTrue((self.root / ".release-notes.json").exists(), "prepare must freeze the approved Chinese task changes")
        notes = json.loads((self.root / ".release-notes.json").read_text())
        self.assertEqual(notes["version"], "1.1.14")
        self.assertEqual([t["id"] for t in notes["tasks"]], ["task-a", "task-b"])
        self.assertEqual(notes["tasks"][1]["changes"], [CHANGE, OTHER])
        self.assertEqual(changelog(notes).count(CHANGE), 1)
        self.assertIn(OTHER, changelog(notes))

    def test_github_notes_come_from_frozen_chinese_changes(self):
        a = self.adapter([CHANGE]); target, meta = self.package(a)
        prepare_release(target, "v1.1.14", "b" * 40)
        notes = (target / "release-notes.md").read_text()
        self.assertTrue(notes.startswith("SignOs 1.1.14（构建 36）\n\n- " + CHANGE))
        self.assertIn("未分发签名", notes)
        self.assertNotIn("sign it with your preferred", notes)

    def test_missing_or_tampered_notes_artifact_cannot_be_released(self):
        for mode in ("missing", "tampered", "wrong-batch", "wrong-task", "wrong-version"):
            with self.subTest(mode=mode):
                a = self.adapter([CHANGE]); target, meta = self.package(a)
                p = target / "release-notes.json"
                if mode == "missing":
                    p.unlink()
                elif mode == "tampered":
                    p.write_text(p.read_text() + " ")
                else:
                    notes = json.loads(p.read_text())
                    if mode == "wrong-batch": notes["batchId"] = "22222222-2222-2222-2222-222222222222"
                    if mode == "wrong-task": notes["tasks"][0]["sha"] = "d" * 40
                    if mode == "wrong-version": notes["version"] = "1.1.13"
                    p.write_text(json.dumps(notes))
                    meta["releaseNotesSha256"] = hashlib.sha256(p.read_bytes()).hexdigest()
                    (target / "build-metadata.json").write_text(json.dumps(meta))
                with self.assertRaises((ValueError, OSError)):
                    prepare_release(target, "v1.1.14", "b" * 40)
                self.assertFalse((target / "release-notes.md").exists())
                shutil.rmtree(target)

    def test_ota_publisher_receives_the_same_chinese_changelog(self):
        a = self.adapter([CHANGE]); self.freeze(a)
        a.ci_package = lambda: (self.artifacts, {"sha256": "e" * 64})
        a.run_ota()
        publications = [c for c in self.commands if "--notes" in c]
        self.assertEqual(len(publications), 2)
        expected = "SignOs 1.1.14（构建 36）\n\n- " + CHANGE
        for command in publications:
            self.assertEqual(command[command.index("--notes") + 1], expected)

    def test_cached_ota_verification_still_rejects_an_english_or_changed_log(self):
        a = self.adapter([CHANGE]); self.freeze(a)
        current = {"version": "1.1.14", "buildNumber": "36", "bundleId": "com.signos.app",
                   "signed": True, "size": 1, "sha256": "e" * 64, "installUrl": "https://example.invalid/install",
                   "downloadUrl": "https://example.invalid/ipa", "manifestUrl": "https://example.invalid/manifest",
                   "notes": "SignOs coordinated release batch " + BATCH}
        a.current = lambda: current
        (self.artifacts / "ota-receipt.json").write_text(json.dumps({**current, "sourceCommit": "b" * 40}))
        a.fetch = lambda _: plistlib.dumps({"items": [{"metadata": {"bundle-version": "36"},
                                                       "assets": [{"url": current["downloadUrl"]}]}]})
        with self.assertRaisesRegex(ValueError, "日志"):
            a.ota_receipt()

    def test_cached_github_verification_still_rejects_missing_chinese_changes(self):
        a = self.adapter([CHANGE]); self.freeze(a)
        assets = [{"id": i, "name": n} for i, n in enumerate(["SignOs.ipa", "build-metadata.json", "SHA256SUMS"])]
        release = {"draft": False, "assets": assets, "body": "SignOs 1.1.14 (build 36).",
                   "html_url": "https://example.invalid/release"}
        a.api = lambda *args, **kwargs: release
        a.runs = lambda _: [{"status": "completed", "conclusion": "success", "id": 1}]
        state = [{k: v.get(k) for k in ("id", "name", "size", "updated_at", "digest")} for v in assets]
        (self.artifacts / "github-verified.json").write_text(json.dumps({"assets": state,
            "commit": "b" * 40, "result": {"url": release["html_url"]}}))
        with self.assertRaisesRegex(ValueError, "日志"):
            a.check_github()

    def test_every_task_in_a_shared_batch_must_provide_its_own_changes(self):
        a = self.adapter([CHANGE])
        a.data["tasks"].append({"id": "task-b", "sha": "c" * 40,
                               "validation": {"checks": [{"status": "passed"}]}})
        with patch("signos_release_adapter.fingerprint", return_value="stable"):
            with self.assertRaisesRegex(ValueError, "task-b.*中文更新日志"):
                a.prepare()
        self.assertFalse((self.artifacts / "prepared.json").exists())
        self.assertEqual(self.commands, [])

    def test_malformed_input_is_rejected_without_side_effects(self):
        for note in (None, [], {"language": "zh-Hans", "changes": [5]},
                     {"language": "zh-Hans", "changes": ["  "]},
                     {"language": "zh-Hans", "changes": ["新增 TODO 功能待补充"]}):
            with self.subTest(note=note):
                a = self.adapter([CHANGE])
                a.data["tasks"][0]["validation"]["releaseNotes"] = note
                with self.assertRaisesRegex(ValueError, "中文更新日志"):
                    a.prepare()
                self.assertFalse((self.artifacts / "prepared.json").exists())
                self.assertEqual(self.commands, [])

    def test_frozen_notes_cannot_substitute_different_ready_changes(self):
        a = self.adapter([CHANGE]); record, manifest = self.freeze(a)
        record["tasks"][0]["changes"] = [OTHER]
        (self.root / ".release-notes.json").write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, "任务就绪记录"):
            a.release_notes()

    def test_valid_cached_ota_remains_reusable_without_resigning(self):
        a = self.adapter([CHANGE]); record, manifest = self.freeze(a)
        current = {"version": "1.1.14", "buildNumber": "36", "bundleId": "com.signos.app",
                   "signed": True, "size": 1, "sha256": "e" * 64, "installUrl": "https://example.invalid/install",
                   "downloadUrl": "https://example.invalid/ipa", "manifestUrl": "https://example.invalid/manifest",
                   "notes": changelog(record)}
        cached = {**current, "sourceCommit": "b" * 40}
        a.current = lambda: current
        (self.artifacts / "ota-receipt.json").write_text(json.dumps(cached))
        a.fetch = lambda _: plistlib.dumps({"items": [{"metadata": {"bundle-version": "36"},
                                                       "assets": [{"url": current["downloadUrl"]}]}]})
        self.assertEqual(a.ota_receipt(), cached)
        self.assertEqual(self.commands, [])

    def test_valid_cached_github_remains_reusable_without_republishing(self):
        a = self.adapter([CHANGE]); record, manifest = self.freeze(a)
        assets = [{"id": i, "name": n} for i, n in enumerate(["SignOs.ipa", "build-metadata.json", "SHA256SUMS"])]
        release = {"draft": False, "assets": assets, "body": changelog(record),
                   "html_url": "https://example.invalid/release"}
        a.api = lambda *args, **kwargs: release
        a.runs = lambda _: [{"status": "completed", "conclusion": "success", "id": 1}]
        state = [{k: v.get(k) for k in ("id", "name", "size", "updated_at", "digest")} for v in assets]
        result = {"url": release["html_url"]}
        (self.artifacts / "github-verified.json").write_text(json.dumps({"assets": state,
            "commit": "b" * 40, "result": result}))
        self.assertEqual(a.check_github(), {"done": True, "result": result})
        self.assertEqual(self.commands, [])

    def test_resuming_a_stage_with_wrong_notes_cannot_activate_it(self):
        from types import SimpleNamespace
        a = self.adapter([CHANGE]); self.freeze(a)
        a.ci_package = lambda: (self.artifacts, {"sha256": "e" * 64})
        output = Path(a.config["outputRoot"]) / "1.1.14"; output.mkdir(parents=True)
        (output / "signed.ipa").write_bytes(b"ipa")
        receipt = {"version": "1.1.14", "buildNumber": "36",
                   "sha256": hashlib.sha256(b"ipa").hexdigest(), "notes": "English batch placeholder"}
        intent = {"sourceCommit": "b" * 40, "unsignedIpaSha256": "e" * 64,
                  "version": "1.1.14", "buildNumber": "36"}
        (self.artifacts / "ota-input.json").write_text(json.dumps(intent))
        a.config["localRoot"] = str(self.root.parent / "channel")
        effects = []
        fake = SimpleNamespace(check_package=lambda _: receipt,
                               stage_local=lambda *args: effects.append("stage"),
                               activate_staged=lambda *args: effects.append("activate"),
                               verify_published=lambda *args, **kwargs: None)
        with patch.dict(sys.modules, {"ios_ota": fake}):
            with self.assertRaisesRegex(ValueError, "日志"):
                a.run_ota()
        self.assertEqual(effects, [])


if __name__ == "__main__":
    unittest.main()
