#!/usr/bin/env python3
"""Prepare and publish unchanged IPAs to the Cloudflare app source."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import hmac
import json
from pathlib import Path
import plistlib
import re
import os
import shlex
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit, quote
from urllib.error import HTTPError
from urllib.request import Request, urlopen
import uuid
import xml.etree.ElementTree as ET
import zipfile


KEEP_VERSIONS = 10
BUDGET_BYTES = 8_000_000_000
LOCK_KEY = '_maintenance/lock.json'
STATE_KEY = '_maintenance/gc.json'


class R2Control:
    """Small SigV4 control requests; IPA bytes continue through rclone/Wrangler."""
    def __init__(self, config):
        self.access = os.environ.get('AWS_ACCESS_KEY_ID')
        self.secret = os.environ.get('AWS_SECRET_ACCESS_KEY')
        if not self.access or not self.secret:
            raise ValueError('S3 credentials required for cloud locking and budget checks')
        account, self.bucket = config['accountId'], config['bucket']
        if not re.fullmatch(r'[a-fA-F0-9]{32}', account) or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]', self.bucket):
            raise ValueError('Invalid R2 account or bucket')
        self.host = account + '.r2.cloudflarestorage.com'

    def request(self, method, key='', data=None, headers=None, query=None):
        now = datetime.now(timezone.utc)
        stamp, day = now.strftime('%Y%m%dT%H%M%SZ'), now.strftime('%Y%m%d')
        path = '/' + self.bucket + '/' + quote(key, safe='/~')
        query_string = '&'.join(quote(k, safe='~') + '=' + quote(str(v), safe='~')
                                for k, v in sorted((query or {}).items()))
        digest = hashlib.sha256(data or b'').hexdigest()
        signed = {'host': self.host, 'x-amz-date': stamp, 'x-amz-content-sha256': digest,
                  **{k.lower(): v for k, v in (headers or {}).items()}}
        if os.environ.get('AWS_SESSION_TOKEN'):
            signed['x-amz-security-token'] = os.environ['AWS_SESSION_TOKEN']
        names = ';'.join(sorted(signed))
        canonical = '\n'.join([method, path, query_string,
                               ''.join(k + ':' + signed[k].strip() + '\n' for k in sorted(signed)), names, digest])
        scope = day + '/auto/s3/aws4_request'
        string = 'AWS4-HMAC-SHA256\n' + stamp + '\n' + scope + '\n' + hashlib.sha256(canonical.encode()).hexdigest()
        signing_key = ('AWS4' + self.secret).encode()
        for part in (day, 'auto', 's3', 'aws4_request'):
            signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(signing_key, string.encode(), hashlib.sha256).hexdigest()
        signed['Authorization'] = f'AWS4-HMAC-SHA256 Credential={self.access}/{scope}, SignedHeaders={names}, Signature={signature}'
        url = 'https://' + self.host + path + ('?' + query_string if query_string else '')
        try:
            with urlopen(Request(url, data=data, headers=signed, method=method), timeout=60) as response:
                return response.read()
        except HTTPError as error:
            if error.code == 404 and method == 'GET':
                return None
            if error.code in (409, 412):
                raise ValueError('Cloud lock busy or object changed; retry later') from None
            raise ValueError(f'R2 control request failed: HTTP {error.code} ({method} {key})') from None

    def get(self, key):
        return self.request('GET', key)

    def put(self, key, data, headers=None):
        return self.request('PUT', key, data, headers)

    def list(self):
        objects, query = {}, {'list-type': '2', 'max-keys': '1000'}
        ns = {'s': 'http://s3.amazonaws.com/doc/2006-03-01/'}
        while True:
            page = ET.fromstring(self.request('GET', query=query))
            for item in page.findall('s:Contents', ns):
                uploaded = datetime.fromisoformat(item.findtext('s:LastModified', namespaces=ns).replace('Z', '+00:00'))
                objects[item.findtext('s:Key', namespaces=ns)] = {
                    'size': int(item.findtext('s:Size', namespaces=ns)),
                    'etag': item.findtext('s:ETag', namespaces=ns).strip('"'),
                    'uploaded': uploaded.isoformat(timespec='milliseconds').replace('+00:00', 'Z'),
                }
            if page.findtext('s:IsTruncated', namespaces=ns) != 'true':
                return objects
            cursor = page.findtext('s:NextContinuationToken', namespaces=ns)
            if not cursor or cursor == query.get('continuation-token'):
                raise ValueError('Incomplete R2 listing')
            query['continuation-token'] = cursor

    @contextmanager
    def lock(self):
        owner = str(uuid.uuid4())
        self.put(LOCK_KEY, json.dumps({'owner': owner, 'kind': 'publish',
                 'startedAt': int(datetime.now(timezone.utc).timestamp() * 1000)}).encode(), {'If-None-Match': '*'})
        try:
            yield
        finally:
            current = self.get(LOCK_KEY)
            if current and json.loads(current).get('owner') == owner:
                self.request('DELETE', LOCK_KEY)


def trim_versions(source):
    if not isinstance(source.get('apps'), list) or not source['apps']:
        raise ValueError('Missing apps')
    for app in source['apps']:
        versions = app.get('versions', [])
        current = next((v for v in versions if v.get('downloadURL') == app.get('downloadURL')), None)
        if current is None or not app.get('downloadURL'):
            raise ValueError('Current release absent from history')
        others = [v for v in versions if v is not current]
        others.sort(key=lambda v: datetime.fromisoformat(v['date'].replace('Z', '+00:00')), reverse=True)
        app['versions'] = [current, *others][:KEEP_VERSIONS]


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
        baseline = root / '.publish-base.sha256'
        if path.exists() and not baseline.exists():
            atomic_write(baseline, hashlib.sha256(path.read_bytes()).hexdigest().encode())
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
    local_before = manifest.read_bytes()
    source = json.loads(local_before)
    if source['sourceURL'] != base + '/source.json':
        raise ValueError('Manifest sourceURL does not match cloud configuration')
    trim_versions(source)
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
    remote = R2Control(config)
    with remote.lock():
        previous = remote.get('source.json')
        baseline = root / '.publish-base.sha256'
        expected = baseline.read_text().strip() if baseline.exists() else hashlib.sha256(local_before).hexdigest()
        if previous is not None and hashlib.sha256(previous).hexdigest() != expected and previous != local_before:
            raise ValueError('Cloud manifest changed; refresh and re-stage on the latest source before syncing')
        objects = remote.list()
        encoded = (json.dumps(source, ensure_ascii=False, indent=2) + '\n').encode()
        # Include orphaned/grace-period files. Pruning history does not free bytes immediately.
        new_bytes = sum((root / key).stat().st_size for key in referenced if key not in objects)
        source_growth = max(0, len(encoded) - objects.get('source.json', {}).get('size', 0))
        projected = sum(obj['size'] for obj in objects.values()) + new_bytes + source_growth + len(previous or b'') + 1024 * 1024
        if projected > BUDGET_BYTES:
            raise ValueError(f'R2 storage budget exceeded: projected {projected} bytes > {BUDGET_BYTES}; publication stopped')
        print(f'R2 budget: projected {projected}/{BUDGET_BYTES} bytes (includes 1 MiB maintenance reserve)')
        state_bytes = remote.get(STATE_KEY)
        state = json.loads(state_bytes) if state_bytes else {'version': 1, 'pending': {}}
        if state.get('version') != 1 or not isinstance(state.get('pending'), dict):
            raise ValueError('Invalid GC state; publication stopped')
        for key in referenced:
            state['pending'].pop(key, None)
        # Clear previous retirement clocks before making a reintroduced file visible.
        remote.put(STATE_KEY, json.dumps(state).encode())
        if previous:
            remote.put('_maintenance/manifests/' + hashlib.sha256(previous).hexdigest() + '.json', previous)
        if not baseline.exists():
            atomic_write(baseline, expected.encode())
        atomic_write(manifest, encoded)
        _upload_locked(args, config, referenced, objects)
        now = int(datetime.now(timezone.utc).timestamp() * 1000)
        for key, obj in objects.items():
            if re.fullmatch(r'files/[A-Za-z0-9._-]+\.(ipa|png)', key) and key not in referenced:
                entry = state['pending'].get(key)
                if not entry or entry.get('etag') != obj['etag'] or entry.get('uploaded') != obj['uploaded']:
                    state['pending'][key] = {'since': now, 'etag': obj['etag'], 'uploaded': obj['uploaded']}
        remote.put(STATE_KEY, json.dumps(state).encode())
        baseline.unlink(missing_ok=True)
    print('Published and verified:', base + '/source.json')


def _upload_locked(args, config, referenced, objects):
    root = Path(config['root']).expanduser().resolve(strict=True)
    base, bucket = config['baseUrl'].rstrip('/'), config['bucket']
    manifest = root / 'source.json'
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
        if key not in objects:
            upload(root / key, key)
        verify(root / key, key)
    upload(manifest, 'source.json')
    with urlopen(Request(base + '/source.json', headers={'User-Agent': 'YaoAppSourcePublisher/1.0'}), timeout=30) as response:
        if response.read() != original_manifest:
            raise ValueError('Cloud manifest verification failed')


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
