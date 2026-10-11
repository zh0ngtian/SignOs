#!/usr/bin/env python3
"""Run the two agreed live-source acceptance cases and independent full-IPA baselines."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import tempfile
import time
from urllib.request import Request, urlopen
import zipfile

from cloud_source import Client, credentials

DIRECT_URL = 'https://github.com/zh0ngtian/ipa-archive/releases/download/bilibili-inter-v3.20.1-b82300200/Bilibili_3.20.1_82300200.ipa'
CASES = [
    ('github-release', {'kind': 'github', 'repository': 'zh0ngtian/codex-mobile', 'assetPattern': 'CodexMobile-*-unsigned.ipa', 'includePrereleases': False}),
    ('direct-ipa', {'kind': 'url', 'url': DIRECT_URL}),
]


def baseline(url):
    started = time.monotonic()
    digest, count = hashlib.sha256(), 0
    with tempfile.TemporaryDirectory(prefix='signos-source-baseline-') as directory:
        ipa = Path(directory) / 'baseline.ipa'
        with urlopen(url, timeout=60) as response, ipa.open('wb') as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk); digest.update(chunk); count += len(chunk)
        downloaded_ms = round((time.monotonic() - started) * 1000)
        with zipfile.ZipFile(ipa) as archive:
            entries = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
            if len(entries) != 1:
                raise ValueError('Expected one main app')
            info = archive.getinfo(entries[0])
            plist = archive.read(entries[0])  # Python independently checks ZIP CRC here.
            value = plistlib.loads(plist)
            metadata = {
                'name': value.get('CFBundleDisplayName') or value.get('CFBundleName'),
                'bundleIdentifier': value.get('CFBundleIdentifier'),
                'version': value.get('CFBundleShortVersionString'),
                'buildVersion': value.get('CFBundleVersion'),
                'minOSVersion': value.get('MinimumOSVersion'),
            }
    return {'metadata': metadata, 'fullBytes': count, 'sha256': digest.hexdigest(), 'crc32': f'{info.CRC:08x}', 'localDownloadMs': downloaded_ms}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=['github-release', 'direct-ipa'])
    args = parser.parse_args()
    client = Client(credentials())
    report = {'sourceURL': client.url + '/sources/yao.json', 'cases': []}
    previous = json.loads(args.output.read_text()) if args.output.exists() else {}
    prior_cases = previous.get('cases', [])
    for case, config in CASES:
        if args.case and args.case != case:
            continue
        existing = next((e for e in client.state()['entries'] if all(e['config'].get(k) == v for k, v in config.items())), None)
        entry_id = existing['id'] if existing else client.create(config)
        if existing and existing['status'] in ('failed', 'retrying'):
            client.call('/api/entries/' + entry_id, 'PATCH', {'revision': client.state()['revision'], 'config': config})
        entry = client.wait(entry_id)
        current = entry['current']
        verified = next((x for x in prior_cases if x['downloadURL'] == current['downloadURL'] and x['inspection'].get('strongETag') == current['inspection'].get('strongETag')), None)
        independent = verified['baseline'] if verified else baseline(current['downloadURL'])
        inspection = current['inspection']
        assert current['metadata'] == independent['metadata'], 'Worker and Python metadata differ'
        assert inspection['fullBytes'] == independent['fullBytes'], 'File size differs'
        assert inspection['crc32'].lower() == independent['crc32'], 'Plist CRC differs'
        if not entry['published']:
            client.confirm(entry_id)
        client.attest(entry_id, independent['sha256'])
        result = {'case': case, 'entryId': entry_id, 'downloadURL': current['downloadURL'], 'metadata': current['metadata'], 'inspection': inspection, 'baseline': independent, 'passed': True}
        report['cases'].append(result)
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'case': case, 'passed': True, 'name': current['metadata']['name'], 'fullBytes': inspection['fullBytes'], 'downloadedBytes': inspection['downloadedBytes'], 'workerElapsedMs': inspection['elapsedMs'], 'localDownloadMs': independent['localDownloadMs']}, ensure_ascii=False), flush=True)
    with urlopen(Request(report['sourceURL'], headers={'User-Agent': 'SignOs-Acceptance/1'}), timeout=30) as response:
        document = json.load(response)
    assert all(any(a['appID'] == x['entryId'] and a['downloadURL'] == x['downloadURL'] and a['sha256'] == x['baseline']['sha256'] for a in document['apps']) for x in report['cases'])
    report['publicJSONVerified'] = True
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
