#!/bin/bash
# Build a device IPA for CI checks without distribution signing or private TLS.
set -euo pipefail

if [[ -n ${RELEASE_TAG:-} ]] && [[ ! $RELEASE_TAG =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo 'Release tags must use vX.Y.Z (for example, v1.0.11).' >&2
  exit 1
fi

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_OUTPUT=${1:?Usage: bash scripts/check_ios_build.sh /path/to/empty-output-directory}
mkdir -p "$BUILD_OUTPUT"
BUILD_OUTPUT=$(cd "$BUILD_OUTPUT" && pwd)
cd "$REPO_ROOT"

xcodebuild \
  -project Feather.xcodeproj \
  -scheme Feather \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_OUTPUT/DerivedData" \
  -resultBundlePath "$BUILD_OUTPUT/Build.xcresult" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  DEPLOYMENT_LOCATION=NO \
  ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO \
  build 2>&1 | tee "$BUILD_OUTPUT/build.log"

mkdir -p "$BUILD_OUTPUT/Payload"
ditto "$BUILD_OUTPUT/DerivedData/Build/Products/Release-iphoneos/SignOs.app" "$BUILD_OUTPUT/Payload/SignOs.app"
ditto -c -k --sequesterRsrc --keepParent "$BUILD_OUTPUT/Payload" "$BUILD_OUTPUT/SignOs.ipa"

python3 - "$BUILD_OUTPUT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import zipfile

output = Path(sys.argv[1])
ipa = output / 'SignOs.ipa'
with zipfile.ZipFile(ipa) as archive:
    if archive.testzip() is not None:
        raise SystemExit('Corrupt IPA archive')
    info = plistlib.loads(archive.read('Payload/SignOs.app/Info.plist'))
    for name in ('server.crt', 'server.pem', 'commonName.txt', 'embedded.mobileprovision'):
        if f'Payload/SignOs.app/{name}' in archive.namelist():
            raise SystemExit(f'Unexpected private distribution resource: {name}')
if info['CFBundleIdentifier'] != 'com.signos.app':
    raise SystemExit('Unexpected bundle identifier')
if tag := os.environ.get('RELEASE_TAG'):
    if info['CFBundleShortVersionString'] != tag[1:]:
        raise SystemExit('Release tag does not match IPA version; update Feather.xcconfig before tagging')
metadata = {
    'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
    'bundleIdentifier': info['CFBundleIdentifier'],
    'version': info['CFBundleShortVersionString'],
    'buildNumber': info['CFBundleVersion'],
    'minimumOSVersion': info['MinimumOSVersion'],
    'distributionSigned': False,
    'size': ipa.stat().st_size,
    'sha256': hashlib.sha256(ipa.read_bytes()).hexdigest(),
}
report = json.dumps(metadata, indent=2) + '\n'
(output / 'build-metadata.json').write_text(report)
print(report)
if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
    with open(summary, 'a') as stream:
        stream.write('iOS Release build and IPA validation passed. '
                     'Artifact requires separate signing before installation.\n\n')
        stream.write(f'```json\n{report}```\n')
PY
