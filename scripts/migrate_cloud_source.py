#!/usr/bin/env python3
"""Migrate only the latest IPA of each existing app to GitHub and Cloudflare."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
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
    parser.add_argument('--skip-bundle', action='append', default=[], help='Skip an app supplied by a separate new release')
    parser.add_argument('--report', type=Path, default=REPO / 'packages/home-source/cloudflare-migration.json')
    args = parser.parse_args()
    source = json.loads((args.source_root / 'source.json').read_text())
    apps = [app for app in source['apps'] if app['bundleIdentifier'] not in args.skip_bundle]
    resources = []
    for app in apps:
        for version in app['versions'][:1]:
            ipa = args.source_root / urlsplit(version['downloadURL']).path.lstrip('/')
            with ipa.open('rb') as stream:
                digest = hashlib.file_digest(stream, 'sha256').hexdigest()
            if ipa.stat().st_size != version['size'] or digest != version['sha256']:
                raise ValueError('IPA differs from source receipt: ' + str(ipa))
        icon = args.source_root / urlsplit(app['iconURL']).path.lstrip('/')
        resources.append({'bundleIdentifier': app['bundleIdentifier'], 'versions': 1, 'iconBytes': icon.stat().st_size})
    print(json.dumps({'plan': args.plan, 'latestOnly': True, 'identity': source['identifier'], 'apps': resources}, ensure_ascii=False), flush=True)
    if args.plan:
        return
    client = Client(credentials())
    report = {'latestOnly': True, 'identity': source['identifier'], 'sourceURL': client.url + '/sources/yao.json', 'apps': []}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    for app in apps:
        bundle = app['bundleIdentifier']
        icon = args.source_root / urlsplit(app['iconURL']).path.lstrip('/')
        icon_destination = REPO / 'distribution/source-aggregator/public/images' / (bundle + '.png')
        icon_destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(icon, icon_destination)
        archived = []
        for version in app['versions'][:1]:
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
        entry = client.sync_to(entry_id, archived[0]['downloadURL'])
        if entry['current']['metadata']['bundleIdentifier'] != bundle:
            raise ValueError('Parsed bundle identifier differs from old source')
        if not entry['published']:
            client.confirm(entry_id)
        client.attest(entry_id, archived[0]['sha256'])
        client.call(f'/api/entries/{entry_id}/presentation', 'POST', {
            'revision': client.state()['revision'], 'developerName': app.get('developerName', ''),
            'description': app.get('localizedDescription', ''), 'iconURL': client.url + '/images/' + bundle + '.png', 'legacyDefault': True,
        })
        entry = client.entry(entry_id)
        report['apps'].append({'bundleIdentifier': bundle, 'entryId': entry_id, 'versions': len(entry['history']) + 1, 'currentSHA256': entry['current']['sha256']})
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    with urlopen(Request(report['sourceURL'], headers={'User-Agent': 'SignOs-Publisher/1'}), timeout=30) as response:
        public = json.load(response)
    if public['identifier'] != source['identifier']:
        raise ValueError('Public source identity changed')
    for migrated in report['apps']:
        public_app = next(a for a in public['apps'] if a.get('appID') == migrated['entryId'])
        original = next(a for a in apps if a['bundleIdentifier'] == migrated['bundleIdentifier'])['versions'][0]
        if (public_app['bundleIdentifier'], public_app['version'], public_app['buildVersion'], public_app['size'], public_app['sha256']) != (migrated['bundleIdentifier'], original['version'], original['buildVersion'], original['size'], original['sha256']):
            raise ValueError('Public latest IPA differs from the old source receipt')
    report['publicJSONVerified'] = True
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
