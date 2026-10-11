#!/usr/bin/env python3
"""Validate CI artifacts before publishing a tagged, unsigned GitHub Release."""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import sys
import zipfile


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

    metadata_digest = hashlib.sha256(metadata_path.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(
        f"{digest}  SignOs.ipa\n{metadata_digest}  build-metadata.json\n"
    )
    (output / "release-notes.md").write_text(
        f"SignOs {tag[1:]} (build {metadata['buildNumber']}).\n\n"
        "Download `SignOs.ipa` and sign it with your preferred signing tool before installation. "
        "This package has no distribution signature or private local TLS resources.\n\n"
        f"Minimum iOS version: {metadata['minimumOSVersion']}.\n\n"
        f"Source commit: `{commit}`.\n\n"
        "Verify the downloads with `shasum -a 256 -c SHA256SUMS`.\n"
    )


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: prepare_github_release.py OUTPUT_DIRECTORY TAG COMMIT")
    try:
        prepare_release(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
    except (KeyError, ValueError, OSError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from error
