#!/usr/bin/env python3
"""Publish staged IPAs to the home HTTPS source, with an optional legacy mirror mode."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.request import Request, urlopen


DEFAULT_CONFIG = Path.home() / '.config/yao-app-source/home-source.json'
HEADERS = {'User-Agent': 'YaoAppSourcePublisher/1.0', 'Accept-Encoding': 'identity'}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic_write(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fchmod(stream.fileno(), 0o644)
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def prepare(config):
    source_root = Path(config['sourceRoot']).expanduser().resolve(strict=True)
    if config.get('mode') != 'primary' and (source_root / '.publish-base.sha256').exists():
        raise ValueError('Cloud publication is pending; finish it before mirroring')
    raw = (source_root / 'source.json').read_bytes()
    source = json.loads(raw)
    if config.get('mode') == 'primary':
        from app_source import trim_versions
        trim_versions(source)
    old = config['sourceBaseUrl'].rstrip('/')
    new = config['baseUrl'].rstrip('/')
    if not old.startswith('https://') or not new.startswith('https://'):
        raise ValueError('Both source URLs must use HTTPS')
    if source['sourceURL'] != old + '/source.json':
        raise ValueError('Unexpected source identity')
    files = {}

    def rewrite(value):
        if isinstance(value, dict):
            return {k: rewrite(v) for k, v in value.items()}
        if isinstance(value, list):
            return [rewrite(v) for v in value]
        if isinstance(value, str) and value.startswith(old + '/'):
            key = value[len(old) + 1:]
            if key.startswith('files/'):
                if not re.fullmatch(r'files/[A-Za-z0-9._-]+\.(ipa|png)', key):
                    raise ValueError('Invalid file URL')
                path = (source_root / key).resolve(strict=True)
                if not path.is_relative_to(source_root):
                    raise ValueError('File escapes source directory')
                files[key] = {'path': path, 'size': path.stat().st_size, 'sha256': digest(path)}
            return new + '/' + key
        return value

    mirrored = rewrite(source)
    for app in source['apps']:
        for release in [app, *app.get('versions', [])]:
            url = release['downloadURL']
            if not url.startswith(old + '/files/'):
                raise ValueError('Release is outside the source')
            entry = files[url[len(old) + 1:]]
            if (entry['size'], entry['sha256']) != (release['size'], release['sha256']):
                raise ValueError('IPA size or SHA-256 mismatch')
    mirrored['description'] = '个人应用软件源，由家中服务器提供 HTTPS 下载。'
    mirrored['message'] = mirrored['description']
    encoded = (json.dumps(mirrored, ensure_ascii=False, indent=2) + '\n').encode()
    return raw, encoded, files


def verify_file(url, entry, full):
    with urlopen(Request(url, method='GET' if full else 'HEAD', headers=HEADERS), timeout=60) as response:
        if int(response.headers.get('Content-Length', -1)) != entry['size']:
            raise ValueError('HTTPS size mismatch: ' + url)
        if full:
            checksum = hashlib.sha256()
            while block := response.read(1024 * 1024):
                checksum.update(block)
            if checksum.hexdigest() != entry['sha256']:
                raise ValueError('HTTPS SHA-256 mismatch: ' + url)


def mirror(config, plan=False, verify_all=False):
    root = Path(config['root']).expanduser().resolve()
    source_root = Path(config['sourceRoot']).expanduser().resolve()
    if root == source_root or root.is_relative_to(source_root) or source_root.is_relative_to(root):
        raise ValueError('Mirror must use a separate directory')
    base = config['baseUrl'].rstrip('/')
    if plan:
        _, _, files = prepare(config)
        return {'sourceURL': base + '/source.json', 'files': len(files),
                'bytes': sum(f['size'] for f in files.values()), 'plan': True}
    root.mkdir(parents=True, exist_ok=True)
    with (root.parent / '.home-publish.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        raw, encoded, files = prepare(config)
        baseline = source_root / '.publish-base.sha256'
        if config.get('mode') == 'primary':
            live = root / 'source.json'
            previous = live.read_bytes() if live.exists() else None
            expected = baseline.read_text().strip() if baseline.exists() else hashlib.sha256(raw).hexdigest()
            if previous is not None and hashlib.sha256(previous).hexdigest() != expected and previous != raw:
                raise ValueError('Home source changed since staging; refresh before publishing')
            occupied = sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
            new_bytes = sum(e['size'] for k, e in files.items() if not (root / k).exists())
            if occupied + new_bytes + len(encoded) > 8_000_000_000:
                raise ValueError('Home source exceeds the 8 GB publication budget')
        else:
            with urlopen(Request(config['sourceBaseUrl'].rstrip('/') + '/source.json', headers=HEADERS), timeout=30) as response:
                if response.read() != raw:
                    raise ValueError('Local source differs from the live cloud manifest')
        receipt_path = root.parent / 'verified-files.json'
        receipts = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
        if receipts.get('baseUrl') != base:
            receipts = {'baseUrl': base, 'files': {}}
        for key, entry in files.items():
            target = root / key
            changed = not target.is_file() or digest(target) != entry['sha256']
            if changed:
                # Copy in chunks; never load a large IPA into memory.
                target.parent.mkdir(parents=True, exist_ok=True)
                with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
                    temporary = Path(stream.name)
                    try:
                        with entry['path'].open('rb') as incoming:
                            while block := incoming.read(1024 * 1024):
                                stream.write(block)
                        stream.flush()
                        os.fchmod(stream.fileno(), 0o644)
                        if digest(temporary) != entry['sha256']:
                            raise ValueError('File changed during copy')
                        temporary.replace(target)
                    finally:
                        temporary.unlink(missing_ok=True)
            identity = {'sha256': entry['sha256'], 'size': entry['size']}
            full = verify_all or changed or receipts['files'].get(key) != identity
            verify_file(base + '/' + key, entry, full)
            receipts['files'][key] = identity
            atomic_write(receipt_path, (json.dumps(receipts, indent=2) + '\n').encode())
        path = root / 'source.json'
        previous = path.read_bytes() if path.exists() else None
        if previous is not None:
            backup = root.parent / 'manifests' / (hashlib.sha256(previous).hexdigest() + '.json')
            atomic_write(backup, previous)
        atomic_write(path, encoded)
        try:
            for endpoint in ('/source.json', '/appstore'):
                with urlopen(Request(base + endpoint, headers=HEADERS), timeout=30) as response:
                    if response.read() != encoded:
                        raise ValueError('Published home manifest mismatch')
        except Exception:
            if previous is not None:
                atomic_write(path, previous)
            else:
                path.unlink(missing_ok=True)
            raise
        if config.get('mode') == 'primary':
            atomic_write(source_root / 'source.json', encoded)
            baseline.unlink(missing_ok=True)
    return {'sourceURL': base + '/source.json', 'files': len(files),
            'bytes': sum(f['size'] for f in files.values()), 'plan': False}


def publish_local(config, verify_all=False):
    """Called while app_source holds the staging directory's publish lock."""
    home = {'mode': 'primary', 'sourceRoot': config['root'], 'sourceBaseUrl': config['baseUrl'],
            'root': config['publicRoot'], 'baseUrl': config['baseUrl']}
    print('Home source:', json.dumps(mirror(home, verify_all=verify_all), ensure_ascii=False))


def sync_if_configured(source_config):
    path = Path(os.environ.get('APP_SOURCE_HOME_CONFIG', str(DEFAULT_CONFIG))).expanduser()
    if not path.exists():
        if 'APP_SOURCE_HOME_CONFIG' in os.environ:
            raise ValueError('Configured home mirror file is missing')
        return
    config = json.loads(path.read_text())
    if config['sourceBaseUrl'].rstrip('/') != source_config['baseUrl'].rstrip('/'):
        raise ValueError('Home mirror configuration targets another cloud source')
    if Path(config['sourceRoot']).expanduser().resolve() != Path(source_config['root']).expanduser().resolve():
        raise ValueError('Home mirror configuration targets another source directory')
    print('Home mirror:', json.dumps(mirror(config), ensure_ascii=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(DEFAULT_CONFIG))
    parser.add_argument('--plan', action='store_true')
    parser.add_argument('--verify-all', action='store_true')
    args = parser.parse_args()
    config = json.loads(Path(args.config).expanduser().read_text())
    source_root = Path(config['sourceRoot']).expanduser()
    if args.plan:
        print(json.dumps(mirror(config, plan=True), ensure_ascii=False, indent=2))
    else:
        with (source_root / '.publish.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            print(json.dumps(mirror(config, verify_all=args.verify_all), ensure_ascii=False, indent=2))
