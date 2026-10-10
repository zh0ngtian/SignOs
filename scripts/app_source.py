#!/usr/bin/env python3
"""Prepare and publish unchanged IPAs to the Cloudflare app source."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import plistlib
import re
import os
import shlex
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zipfile


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    temporary.replace(path)


def file_digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic_copy(source, target):
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            with source.open('rb') as incoming:
                shutil.copyfileobj(incoming, stream, 1024 * 1024)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    temporary.replace(target)


def publish(args, config):
    ipa = Path(args.ipa).expanduser().resolve(strict=True)
    digest = file_digest(ipa)
    if digest != args.sha256:
        raise ValueError('IPA does not match the expected SHA-256')
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise ValueError('Corrupt IPA archive')
        names = [n for n in archive.namelist() if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', n)]
        if len(names) != 1:
            raise ValueError('Expected exactly one main app')
        info = plistlib.loads(archive.read(names[0]))
    bundle = info['CFBundleIdentifier']
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    root = Path(config['root']).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    base = config['baseUrl'].rstrip('/')
    if urlsplit(base).scheme != 'https':
        raise ValueError('An HTTPS base URL is required')
    with (root / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        files = root / 'files'
        files.mkdir(exist_ok=True)
        filename = re.sub(r'[^A-Za-z0-9._-]', '_', f'{bundle}-{version}-{build}-{digest[:16]}.ipa')
        target = files / filename
        if target.exists():
            if file_digest(target) != digest:
                raise ValueError('Existing release content mismatch')
        else:
            atomic_copy(ipa, target)
        icon = Path(args.icon).expanduser().read_bytes()
        if not icon.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('App icon must be PNG')
        icon_name = hashlib.sha256(icon).hexdigest()[:20] + '.png'
        atomic_write(files / icon_name, icon)
        path = root / 'source.json'
        source = json.loads(path.read_text()) if path.exists() else {
            'name': config['name'], 'identifier': config['identifier'],
            'subtitle': 'Yao 的应用软件源',
            'description': '个人应用软件源，由 Cloudflare 提供 HTTPS 下载。',
            'apps': [], 'news': [],
        }
        date = args.date or datetime.now(timezone.utc).isoformat(timespec='seconds')
        release = {'version': version, 'buildVersion': build, 'date': date,
                   'localizedDescription': args.notes, 'downloadURL': base + '/files/' + filename,
                   'size': ipa.stat().st_size, 'sha256': digest,
                   'minOSVersion': info.get('MinimumOSVersion', '15.0')}
        old = next((a for a in source['apps'] if a['bundleIdentifier'] == bundle), {})
        versions = [v for v in old.get('versions', [])
                    if (v['version'], v.get('buildVersion')) != (version, build)]
        app = {**old, 'name': info.get('CFBundleDisplayName') or info.get('CFBundleName') or bundle,
               'bundleIdentifier': bundle, 'developerName': args.developer,
               'localizedDescription': args.description, 'iconURL': base + '/files/' + icon_name,
               'versions': [release, *versions], 'version': version, 'buildVersion': build,
               'versionDate': date, 'versionDescription': args.notes, 'size': release['size'],
               'downloadURL': release['downloadURL'], 'sha256': digest,
               'minOSVersion': release['minOSVersion']}
        source['apps'] = [a for a in source['apps'] if a['bundleIdentifier'] != bundle] + [app]
        source.update(name=config['name'], identifier=config['identifier'],
                      sourceURL=base + '/source.json')
        source.setdefault('iconURL', app['iconURL'])
        source['sourceicon'] = source['iconURL']
        source['message'] = source['description']
        atomic_write(path, (json.dumps(source, ensure_ascii=False, indent=2) + '\n').encode())
    print(json.dumps({'sourceURL': source['sourceURL'], 'app': app}, ensure_ascii=False, indent=2))


def migrate(args, config):
    """Stage a separate cloud copy without mutating the live LAN source."""
    source_root = Path(args.from_root).expanduser().resolve(strict=True)
    root = Path(config['root']).expanduser().resolve()
    if root == source_root:
        raise ValueError('Migration destination must differ from the live source')
    source = json.loads((source_root / 'source.json').read_text())
    old_base = source['sourceURL'].rsplit('/', 1)[0]
    base = config['baseUrl'].rstrip('/')
    def rewrite(value):
        if isinstance(value, dict):
            return {key: rewrite(item) for key, item in value.items()}
        if isinstance(value, list):
            return [rewrite(item) for item in value]
        if isinstance(value, str) and value.startswith(old_base + '/'):
            return base + value[len(old_base):]
        return value
    source = rewrite(source)
    source.update(subtitle='Yao 的应用软件源',
                  description='个人应用软件源，由 Cloudflare 提供 HTTPS 下载。')
    source['message'] = source['description']
    (root / 'files').mkdir(parents=True, exist_ok=True)
    for path in (source_root / 'files').iterdir():
        if path.is_file() and re.fullmatch(r'[A-Za-z0-9._-]+\.(ipa|png)', path.name):
            atomic_copy(path, root / 'files' / path.name)
    atomic_write(root / 'source.json', (json.dumps(source, ensure_ascii=False, indent=2) + '\n').encode())
    print('Staged:', source['sourceURL'])


def sync(args, config):
    root = Path(config['root']).expanduser().resolve(strict=True)
    with (root / '.publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _sync_locked(args, config)


def _sync_locked(args, config):
    """Upload immutable resources first, verify bytes, then publish the manifest."""
    root = Path(config['root']).expanduser().resolve(strict=True)
    base = config['baseUrl'].rstrip('/')
    bucket = config['bucket']
    manifest = root / 'source.json'
    source = json.loads(manifest.read_text())
    if source['sourceURL'] != base + '/source.json':
        raise ValueError('Manifest sourceURL does not match cloud configuration')
    referenced = set()
    def collect(value):
        if isinstance(value, dict):
            for item in value.values(): collect(item)
        elif isinstance(value, list):
            for item in value: collect(item)
        elif isinstance(value, str) and value.startswith(base + '/files/'):
            key = value[len(base) + 1:]
            if not re.fullmatch(r'files/[A-Za-z0-9._-]+\.(ipa|png)', key):
                raise ValueError('Invalid source file URL')
            referenced.add(key)
    collect(source)
    for key in referenced:
        if not (root / key).is_file():
            raise ValueError('Missing source file: ' + key)
    for app in source['apps']:
        for release in [app, *app.get('versions', [])]:
            url = release.get('downloadURL', '')
            if not url.startswith(base + '/files/'):
                raise ValueError('Download URL is outside the cloud source')
            path = root / url[len(base) + 1:]
            if path.stat().st_size != release['size'] or file_digest(path) != release['sha256']:
                raise ValueError('Release size or SHA-256 mismatch: ' + str(path))
    if args.transport == 'wrangler' and any((root / k).stat().st_size > 300 * 1024 * 1024 for k in referenced):
        raise ValueError('Use --transport s3 for files larger than 300 MiB (multipart upload)')
    def upload(path, key):
        if args.transport == 's3':
            if not os.environ.get('AWS_ACCESS_KEY_ID') or not os.environ.get('AWS_SECRET_ACCESS_KEY'):
                raise ValueError('Set R2 S3 AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in the environment')
            command = ['rclone', 'copyto', str(path), ':s3:' + bucket + '/' + key,
                       '--s3-provider', 'Cloudflare', '--s3-env-auth',
                       '--s3-endpoint', config['accountId'] + '.r2.cloudflarestorage.com',
                       '--s3-no-check-bucket', '--s3-chunk-size', '16Mi', '--s3-upload-cutoff', '64Mi']
        else:
            command = shlex.split(os.environ.get('WRANGLER_COMMAND', 'npx wrangler')) + [
                'r2', 'object', 'put', bucket + '/' + key, '--remote', '--file', str(path)]
        subprocess.run(command, check=True)
    def verify(path, key):
        digest = hashlib.sha256()
        count = 0
        with urlopen(Request(base + '/' + key, headers={'User-Agent': 'YaoAppSourcePublisher/1.0'}), timeout=120) as response:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                count += len(chunk)
        if count != path.stat().st_size or digest.hexdigest() != file_digest(path):
            raise ValueError('Cloud verification failed: ' + key)
    original_manifest = manifest.read_bytes()
    for key in sorted(referenced):
        upload(root / key, key)
        verify(root / key, key)
    upload(manifest, 'source.json')
    with urlopen(Request(base + '/source.json', headers={'User-Agent': 'YaoAppSourcePublisher/1.0'}), timeout=30) as response:
        if response.read() != original_manifest:
            raise ValueError('Cloud manifest verification failed')
    print('Published and verified:', base + '/source.json')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    migration = commands.add_parser('migrate')
    migration.add_argument('--from-root', required=True)
    upload_cloud = commands.add_parser('sync')
    upload_cloud.add_argument('--transport', choices=['wrangler', 's3'], default='wrangler')
    upload = commands.add_parser('publish')
    for name in ('ipa', 'sha256', 'icon', 'developer', 'description', 'notes'):
        upload.add_argument('--' + name, required=True)
    upload.add_argument('--date')
    args = parser.parse_args()
    config = json.loads(Path(args.config).expanduser().read_text())
    if args.command == 'publish':
        publish(args, config)
    elif args.command == 'migrate':
        migrate(args, config)
    elif args.command == 'sync':
        sync(args, config)


if __name__ == '__main__':
    main()
