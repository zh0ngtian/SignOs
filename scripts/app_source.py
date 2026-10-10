#!/usr/bin/env python3
"""Publish unchanged IPAs to an AltStore-compatible local HTTPS app source."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import ssl
import tempfile
from urllib.parse import unquote, urlsplit
import zipfile


def atomic_write(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    temporary.replace(path)


def publish(args, config):
    ipa = Path(args.ipa).expanduser().resolve(strict=True)
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
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
            if hashlib.sha256(target.read_bytes()).hexdigest() != digest:
                raise ValueError('Existing release content mismatch')
        else:
            atomic_write(target, ipa.read_bytes())
        icon = Path(args.icon).expanduser().read_bytes()
        if not icon.startswith(b'\x89PNG\r\n\x1a\n'):
            raise ValueError('App icon must be PNG')
        icon_name = hashlib.sha256(icon).hexdigest()[:20] + '.png'
        atomic_write(files / icon_name, icon)
        path = root / 'source.json'
        source = json.loads(path.read_text()) if path.exists() else {
            'name': config['name'], 'identifier': config['identifier'],
            'subtitle': 'Yao 的本机应用软件源',
            'description': '个人应用软件源，仅同一局域网可访问。',
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


def serve(config):
    root = Path(config['root']).expanduser().resolve(strict=True)

    class Handler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(root), **kwargs)

        def send_head(self):
            parts = urlsplit(self.path)
            path = unquote(parts.path)
            if path in ('/appstore', '/source.json'):
                path = '/source.json'
            elif not re.fullmatch(r'/files/[A-Za-z0-9._-]+\.(ipa|png)', path):
                self.send_error(404)
                return None
            target = (root / path.lstrip('/')).resolve()
            if not target.is_relative_to(root) or not target.is_file():
                self.send_error(404)
                return None
            self.path = path
            return super().send_head()

        def guess_type(self, path):
            return {'.ipa': 'application/octet-stream', '.json': 'application/json; charset=utf-8',
                    '.png': 'image/png'}.get(Path(path).suffix, 'application/octet-stream')

        def end_headers(self):
            self.send_header('Cache-Control', 'no-cache' if self.path == '/source.json' else 'public, max-age=3600')
            self.send_header('X-Content-Type-Options', 'nosniff')
            super().end_headers()

    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config['tlsCertificate'], config['tlsKey'])
    server = ThreadingHTTPServer(('0.0.0.0', config['port']), Handler)
    server.daemon_threads = True
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    print(f'{config["name"]}: {config["baseUrl"]}/source.json', flush=True)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('serve')
    upload = commands.add_parser('publish')
    for name in ('ipa', 'sha256', 'icon', 'developer', 'description', 'notes'):
        upload.add_argument('--' + name, required=True)
    upload.add_argument('--date')
    args = parser.parse_args()
    config = json.loads(Path(args.config).expanduser().read_text())
    if args.command == 'serve':
        serve(config)
    else:
        publish(args, config)


if __name__ == '__main__':
    main()
