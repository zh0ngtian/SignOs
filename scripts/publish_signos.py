#!/usr/bin/env python3
"""Publish an existing SignOs OTA release to Yao App Source without resigning."""
import argparse
import json
from pathlib import Path
import plistlib
import re
from types import SimpleNamespace
import zipfile

import app_source
from source_config import load_config


REPO = Path(__file__).resolve().parents[1]


def prepare(args):
    ipa = Path(args.ipa).expanduser().resolve(strict=True)
    receipt = json.loads(Path(args.release_json).expanduser().read_text())
    if receipt.get('signed') is not True or receipt.get('bundleId') != 'com.signos.app':
        raise ValueError('Expected a signed SignOs OTA release receipt')
    if ipa.stat().st_size != receipt['size'] or app_source.file_digest(ipa) != receipt['sha256']:
        raise ValueError('IPA size or SHA-256 does not match the OTA receipt')
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt IPA archive')
        names = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
        if len(names) != 1:
            raise ValueError('Expected exactly one main app')
        info = plistlib.loads(archive.read(names[0]))
    actual = (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion'])
    expected = (receipt['bundleId'], receipt['version'], receipt['buildNumber'])
    if actual != expected:
        raise ValueError('IPA identity/version/build does not match the OTA receipt')
    return SimpleNamespace(
        ipa=str(ipa), sha256=receipt['sha256'],
        icon=str(REPO / 'Feather/Resources/Assets.xcassets/AppIcon.appiconset/feather.png'),
        developer='zh0ngtian / ihateios',
        description='基于 Feather 的 iOS 应用签名、安装与更新工具，支持软件源、后台签名及自动更新。',
        notes=receipt['notes'], date=receipt['publishedAt'],
    ), receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, help='Distribution-signed IPA from the OTA release')
    parser.add_argument('--release-json', required=True, help='Matching OTA latest-ios.json / saved release receipt')
    parser.add_argument('--config', default=str(REPO / 'hosting/home-source/source.config.json'))
    parser.add_argument('--transport', choices=['local', 's3', 'wrangler'], default='local')
    parser.add_argument('--upload-workers', type=app_source.upload_workers, default=4)
    parser.add_argument('--verify-all', action='store_true', help='Ignore receipts and download every resource for verification')
    parser.add_argument('--plan', action='store_true', help='Validate inputs without staging or uploading')
    args = parser.parse_args()
    config = load_config(args.config)
    # The source configuration's relative root is repository-relative, as in the documented CLI.
    root = Path(config['root']).expanduser()
    config['root'] = str(root if root.is_absolute() else REPO / root)
    if 'publicRoot' in config:
        public = Path(config['publicRoot']).expanduser()
        config['publicRoot'] = str(public if public.is_absolute() else REPO / public)
    if config.get('disabled'):
        raise ValueError('This source is retired; use the home source configuration')
    publish_args, receipt = prepare(args)
    print(json.dumps({
        'plan': args.plan, 'version': receipt['version'], 'buildNumber': receipt['buildNumber'],
        'sha256': receipt['sha256'], 'size': receipt['size'],
        'sourceURL': config['baseUrl'].rstrip('/') + '/source.json', 'transport': args.transport,
    }, ensure_ascii=False, indent=2))
    if not args.plan:
        if config.get('backend') == 'home':
            publish_args.verify_all = args.verify_all
            app_source.publish_home(publish_args, config)
        else:
            app_source.publish(publish_args, config)
            app_source.sync(args, config)


if __name__ == '__main__':
    main()
