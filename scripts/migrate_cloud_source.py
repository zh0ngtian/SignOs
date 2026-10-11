#!/usr/bin/env python3
"""Migrate existing source bytes to GitHub and automatically parsed Cloudflare metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import time
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

from cloud_source import Client, credentials, archive_asset, REPO
from test_cloud_source import DIRECT_URL

KEYS = {
    'tech.zh0ngtian.MuseumMuse': ('museum-muse', 'MuseumMuse.ipa'),
    'com.signos.app': ('signos', 'SignOs.ipa'),
    'vip.loock.codexmobile': ('codex-mobile-signed', 'CodexMobile-signed.ipa'),
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=REPO / 'packages/home-source/staging')
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--report', type=Path, default=REPO / 'packages/home-source/cloudflare-migration.json')
    args = parser.parse_args()
    source = json.loads((args.source_root / 'source.json').read_text())
    resources = []
    for app in source['apps']:
        for version in app['versions']:
            ipa = args.source_root / urlsplit(version['downloadURL']).path.lstrip('/')
            if ipa.stat().st_size != version['size'] or hashlib.file_digest(ipa.open('rb'), 'sha256').hexdigest() != version['sha256']:
                raise ValueError('IPA differs from source receipt: ' + str(ipa))
        icon = args.source_root / urlsplit(app['iconURL']).path.lstrip('/')
        resources.append({'bundleIdentifier': app['bundleIdentifier'], 'versions': len(app['versions']), 'iconBytes': icon.stat().st_size})
    print(json.dumps({'plan': args.plan, 'identity': source['identifier'], 'apps': resources}, ensure_ascii=False), flush=True)
    if args.plan:
        return
    client = Client(credentials())
    report = {'identity': source['identifier'], 'sourceURL': client.url + '/sources/yao.json', 'apps': []}
    for app in source['apps']:
        bundle = app['bundleIdentifier']
        icon = args.source_root / urlsplit(app['iconURL']).path.lstrip('/')
        icon_destination = REPO / 'distribution/source-aggregator/public/images' / (bundle + '.png')
        icon_destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(icon, icon_destination)
        archived = []
        for version in reversed(app['versions']):
            if bundle == 'com.bilibili.inter':
                download = DIRECT_URL
            else:
                key, filename = KEYS[bundle]
                tag = f"{key}/v{version['version']}-{version['buildVersion']}"
                ipa = args.source_root / urlsplit(version['downloadURL']).path.lstrip('/')
                download = archive_asset(ipa, tag, filename, version['sha256'])
            archived.insert(0, {**version, 'downloadURL': download})
            print(json.dumps({'archived': bundle, 'version': version['version'], 'build': version['buildVersion'], 'sha256': version['sha256']}, ensure_ascii=False), flush=True)
        if bundle == 'com.bilibili.inter':
            config = {'kind': 'url', 'url': DIRECT_URL}
        else:
            key, filename = KEYS[bundle]
            config = {'kind': 'github', 'repository': 'zh0ngtian/ipa-archive', 'tagPrefix': key + '/', 'assetPattern': filename, 'includePrereleases': False}
        existing = next((e for e in client.state()['entries'] if all(e['config'].get(k) == v for k, v in config.items())), None)
        entry_id = existing['id'] if existing else client.create(config)
        if not existing:
            entry = client.wait(entry_id)
        else:
            entry = existing
        if entry['current']['metadata']['bundleIdentifier'] != bundle:
            raise ValueError('Parsed bundle identifier differs from old source')
        if not entry['published']:
            client.confirm(entry_id)
        client.attest(entry_id, archived[0]['sha256'])
        client.call(f'/api/entries/{entry_id}/presentation', 'POST', {
            'revision': client.state()['revision'], 'developerName': app.get('developerName', ''),
            'description': app.get('localizedDescription', ''), 'iconURL': client.url + '/images/' + bundle + '.png', 'legacyDefault': True,
        })
        if len(archived) > 1:
            client.call(f'/api/entries/{entry_id}/history', 'POST', {'revision': client.state()['revision'], 'versions': archived[1:]})
            deadline = time.monotonic() + 600
            while time.monotonic() < deadline:
                state = client.state()
                jobs = [j for j in state['jobs'] if j['entryId'] == entry_id and j.get('kind') == 'history']
                failed = [j for j in jobs if j['status'] == 'failed']
                if failed:
                    raise RuntimeError('Historical IPA validation failed: ' + json.dumps(client.entry(entry_id)['error'], ensure_ascii=False))
                if all(j['status'] in ('succeeded', 'superseded') for j in jobs):
                    break
                time.sleep(2)
            else:
                raise TimeoutError('Historical IPA validation did not finish')
        entry = client.entry(entry_id)
        if len(entry['history']) < len(archived) - 1:
            raise ValueError('Historical versions missing')
        report['apps'].append({'bundleIdentifier': bundle, 'entryId': entry_id, 'versions': len(entry['history']) + 1, 'currentSHA256': entry['current']['sha256']})
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
