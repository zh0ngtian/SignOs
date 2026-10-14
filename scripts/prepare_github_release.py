#!/usr/bin/env python3
"""Validate CI artifacts before publishing a tagged, unsigned GitHub Release."""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import zipfile
from release_notes import load_notes, changelog


def prepare_release(output: Path, tag: str, commit: str) -> None:
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("Release tags must use vX.Y.Z")
    ipa = output / "SignOs.ipa"
    metadata_path = output / "build-metadata.json"
    metadata = json.loads(metadata_path.read_text())
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    if metadata["commit"] != commit:
        raise ValueError("Artifact commit does not match the release commit")
    if metadata["version"] != tag[1:]:
        raise ValueError("Release tag does not match IPA version")
    if metadata["sha256"] != digest or metadata["size"] != ipa.stat().st_size:
        raise ValueError("IPA checksum or size does not match build metadata")
    if metadata["distributionSigned"] is not False:
        raise ValueError("Expected an IPA without distribution signing")
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError("Corrupt IPA archive")
        info = plistlib.loads(archive.read("Payload/SignOs.app/Info.plist"))
        for name in ("server.crt", "server.pem", "commonName.txt", "embedded.mobileprovision"):
            if f"Payload/SignOs.app/{name}" in archive.namelist():
                raise ValueError(f"Unexpected private distribution resource: {name}")
    for key, value in {
        "CFBundleIdentifier": "com.signos.app",
        "CFBundleShortVersionString": tag[1:],
        "CFBundleVersion": metadata["buildNumber"],
        "MinimumOSVersion": metadata["minimumOSVersion"],
    }.items():
        if info[key] != value:
            raise ValueError(f"IPA {key} does not match release metadata")
    if metadata["bundleIdentifier"] != info["CFBundleIdentifier"]:
        raise ValueError("Bundle identifier does not match build metadata")

    if not metadata.get("batchId"):
        raise ValueError("发布产物缺少冻结批次与具体中文更新日志")
    if metadata.get("batchId"):
        manifest_path = output / "release-batch.json"
        manifest = json.loads(manifest_path.read_text())
        if hashlib.sha256(manifest_path.read_bytes()).hexdigest() != metadata["batchManifestSha256"]:
            raise ValueError("Frozen batch manifest checksum mismatch")
        if manifest["batchId"] != metadata["batchId"] or manifest["scope"] != metadata["releaseScope"]:
            raise ValueError("Artifact belongs to another release batch")
        if manifest["prepared"]["version"] != metadata["version"] or manifest["prepared"]["buildNumber"] != metadata["buildNumber"]:
            raise ValueError("Artifact version differs from frozen batch")

    notes_path = output / "release-notes.json"
    notes = load_notes(notes_path, manifest)
    if hashlib.sha256(notes_path.read_bytes()).hexdigest() != metadata.get("releaseNotesSha256"):
        raise ValueError("Frozen Chinese release notes checksum mismatch")

    metadata_digest = hashlib.sha256(metadata_path.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(
        f"{digest}  SignOs.ipa\n{metadata_digest}  build-metadata.json\n"
    )
    (output / "release-notes.md").write_text(
        changelog(notes) + "\n\n"
        "此处的 `SignOs.ipa` 是未分发签名的构建产物，安装前需要使用签名工具签名；"
        "不包含私有本地 TLS 资源。\n\n"
        f"最低 iOS 版本：{metadata['minimumOSVersion']}。\n\n"
        f"源码提交：`{commit}`。\n\n"
        "下载后可用 `shasum -a 256 -c SHA256SUMS` 核对完整校验和。\n"
    )


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: prepare_github_release.py OUTPUT_DIRECTORY TAG COMMIT")
    try:
        prepare_release(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    except (KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from error
