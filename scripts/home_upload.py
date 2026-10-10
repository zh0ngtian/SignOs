#!/usr/bin/env python3
"""Single-token IPA ingestion behind the home source's HTTPS reverse proxy."""
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import shutil
import socket
import tempfile
import threading
from types import SimpleNamespace
from urllib.parse import parse_qs, urlsplit
from xml.parsers.expat import ExpatError
import zipfile

import app_source
import home_source
from source_config import load_config

REPO = Path(__file__).resolve().parents[1]
MAX_UPLOAD = 2 * 1024**3
PNG = b'\x89PNG\r\n\x1a\n'


class UploadError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message


def inspect_ipa(path):
    """Read bounded metadata; never extract paths supplied by an archive."""
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > 100_000 or sum(e.file_size for e in entries) > app_source.BUDGET_BYTES:
                raise ValueError('IPA expanded size exceeds the 8 GB limit')
            if any(e.flag_bits & 1 for e in entries):
                raise ValueError('Encrypted ZIP archives are not supported')
            if archive.testzip() is not None:
                raise ValueError('Corrupt IPA archive')
            matches = [e for e in entries if re.fullmatch(r'Payload/[^/]+\.app/Info.plist', e.filename)]
            if len(matches) != 1 or matches[0].file_size > 1024 * 1024:
                raise ValueError('Expected exactly one bounded main app Info.plist')
            info = plistlib.loads(archive.read(matches[0]))
            if not isinstance(info, dict):
                raise ValueError('Main app Info.plist must be a dictionary')
            for key in ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion'):
                value = info.get(key)
                if not isinstance(value, str) or not value or len(value) > 255 or any(ord(c) < 32 for c in value):
                    raise ValueError('Missing or invalid ' + key)
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', info['CFBundleIdentifier']):
                raise ValueError('Invalid bundle identifier')
            for key in ('CFBundleDisplayName', 'CFBundleName', 'MinimumOSVersion'):
                if key in info and (not isinstance(info[key], str) or len(info[key]) > 255):
                    raise ValueError('Invalid ' + key)
            prefix = matches[0].filename.rsplit('/', 1)[0] + '/'
            icons = [e for e in entries if e.filename.startswith(prefix)
                     and '/' not in e.filename[len(prefix):]
                     and re.match(r'(?:AppIcon|Icon).*\.png$', e.filename[len(prefix):], re.I)
                     and e.file_size <= 4 * 1024**2]
            for entry in sorted(icons, key=lambda e: e.file_size, reverse=True):
                icon = archive.read(entry)
                if icon.startswith(PNG) and icon[12:16] != b'CgBI':
                    return info, icon
            return info, None
    except (ValueError, KeyError, TypeError, zipfile.BadZipFile, RuntimeError, EOFError,
            plistlib.InvalidFileException, NotImplementedError, ExpatError) as error:
        raise UploadError(400, 'Invalid IPA: ' + str(error)) from None


class UploadService:
    def __init__(self, config, token, fallback_icon, max_upload=MAX_UPLOAD):
        if config.get('backend') != 'home' or config.get('disabled'):
            raise ValueError('Upload requires the active home source')
        if len(token) < 32 or any(c.isspace() for c in token):
            raise ValueError('Upload token must contain at least 32 non-whitespace characters')
        self.config, self.token, self.max_upload = config, token.encode(), max_upload
        self.fallback_icon = Path(fallback_icon).read_bytes()
        if not self.fallback_icon.startswith(PNG):
            raise ValueError('Fallback icon must be PNG')
        self.incoming = Path(config['root']).parent / 'incoming'
        self.incoming.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.slots = threading.BoundedSemaphore(2)

    def publish(self, ipa, checksum, metadata):
        info, icon = inspect_ipa(ipa)
        bundle = info['CFBundleIdentifier']
        if bundle == 'com.signos.app':
            raise UploadError(403, 'SignOs requires the OTA receipt; use scripts/publish_signos.py')
        config = self.config
        with app_source.source_lock(config):
            staging = Path(config['root'])
            public = Path(config['publicRoot'])
            # Separate CLI preparation must finish before remote uploads can begin.
            if (staging / '.publish-base.sha256').exists() or (
                    (staging / 'source.json').exists() and (public / 'source.json').exists()
                    and (staging / 'source.json').read_bytes() != (public / 'source.json').read_bytes()):
                raise UploadError(409, 'A local publication is pending; finish or restore it first')
            source = json.loads((public / 'source.json').read_text()) if (public / 'source.json').exists() else {'apps': []}
            old = next((a for a in source['apps'] if a['bundleIdentifier'] == bundle), {})
            for release in old.get('versions', []):
                if (release.get('version'), release.get('buildVersion')) == (
                        info['CFBundleShortVersionString'], info['CFBundleVersion']):
                    if release.get('sha256') != checksum:
                        raise UploadError(409, 'This version/build already exists with different IPA bytes')
                    key = urlsplit(release['downloadURL']).path.lstrip('/')
                    if not re.fullmatch(r'files/[A-Za-z0-9._-]+\.ipa', key):
                        raise UploadError(409, 'Existing release has an invalid download path')
                    try:
                        if home_source.digest(public / key) != checksum:
                            raise ValueError('Existing IPA checksum mismatch')
                        home_source.verify_file(release['downloadURL'], release, full=False)
                    except (ValueError, OSError) as error:
                        raise UploadError(502, 'Existing release verification failed') from error
                    return 200, {'sourceURL': config['baseUrl'] + '/source.json', 'duplicate': True,
                                 'bundleIdentifier': bundle, **release}
            occupied = sum(p.stat().st_size for p in public.rglob('*') if p.is_file())
            if occupied + ipa.stat().st_size + len(icon or self.fallback_icon) > app_source.BUDGET_BYTES:
                raise UploadError(507, 'Home source exceeds the 8 GB publication budget')
            icon_path = ipa.with_suffix('.png')
            icon_path.write_bytes(icon or self.fallback_icon)
            args = SimpleNamespace(ipa=str(ipa), sha256=checksum, icon=str(icon_path), date=None,
                                   developer=metadata.get('developer', old.get('developerName', 'Community')),
                                   description=metadata.get('description', old.get('localizedDescription', '')),
                                   notes=metadata.get('notes', ''), verify_all=False)
            try:
                result = app_source.publish_home(args, config, locked=True, quiet=True)
            except (ValueError, OSError, zipfile.BadZipFile, RuntimeError) as error:
                # Do not expose internal paths, request headers or credentials.
                print(json.dumps({'event': 'publication_failed', 'errorType': type(error).__name__}), flush=True)
                raise UploadError(502, 'Publication failed; the previous source remains available. Retry later.') from None
            app = result['app']
            return 201, {'sourceURL': result['sourceURL'], 'duplicate': False,
                         'bundleIdentifier': bundle, **app['versions'][0]}


class UploadHandler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    server_version = 'YaoUpload/1.0'
    sys_version = ''

    def setup(self):
        super().setup()
        self.connection.settimeout(300)

    def reply(self, status, value):
        body = (json.dumps(value, ensure_ascii=False) + '\n').encode()
        self.close_connection = True
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def validate(self):
        service = self.server.service
        url = urlsplit(self.path)
        if url.path != '/api/upload':
            raise UploadError(404, 'Not found')
        auth = self.headers.get_all('Authorization', [])
        expected = b'Bearer ' + service.token
        if len(auth) != 1 or not hmac.compare_digest(auth[0].encode(), expected):
            raise UploadError(401, 'Invalid or missing Bearer token')
        if self.command != 'POST':
            raise UploadError(405, 'Use POST with the IPA as the raw request body')
        lengths = self.headers.get_all('Content-Length', [])
        if self.headers.get('Transfer-Encoding'):
            raise UploadError(400, 'Chunked uploads are not supported; provide Content-Length')
        if len(lengths) != 1 or not re.fullmatch(r'[0-9]{1,20}', lengths[0]):
            raise UploadError(411, 'Provide a single valid Content-Length')
        length = int(lengths[0])
        if length < 1 or length > service.max_upload:
            raise UploadError(413, 'IPA must be non-empty and no larger than 2 GiB')
        if self.headers.get('Content-Type', '').split(';')[0].strip().lower() not in (
                'application/octet-stream', 'application/vnd.iphone', 'application/x-itunes-ipa'):
            raise UploadError(415, 'Use Content-Type: application/octet-stream (raw IPA, not multipart)')
        checksum = self.headers.get('X-IPA-SHA256', '')
        if checksum and not re.fullmatch(r'[a-fA-F0-9]{64}', checksum):
            raise UploadError(400, 'Invalid X-IPA-SHA256')
        if len(url.query) > 8192:
            raise UploadError(400, 'Metadata is too long')
        try:
            values = parse_qs(url.query, keep_blank_values=True, max_num_fields=3, encoding='utf-8', errors='strict')
        except (ValueError, UnicodeError):
            raise UploadError(400, 'Invalid metadata') from None
        if any(k not in ('developer', 'description', 'notes') or len(v) != 1 or len(v[0]) > 2000
               for k, v in values.items()):
            raise UploadError(400, 'Only developer, description and notes metadata are supported (2000 characters each)')
        return length, checksum.lower(), {k: v[0] for k, v in values.items()}

    def handle_expect_100(self):
        try:
            self.validate()
        except UploadError as error:
            self.reply(error.status, {'error': error.message})
            return False
        self.send_response_only(100)
        self.end_headers()
        return True

    def do_POST(self):
        service = self.server.service
        acquired = False
        try:
            length, expected, metadata = self.validate()
            acquired = service.slots.acquire(blocking=False)
            if not acquired:
                raise UploadError(503, 'Two uploads are already in progress; retry later')
            if shutil.disk_usage(service.incoming).free < 3 * length + 64 * 1024**2:
                raise UploadError(507, 'Insufficient free disk space for this IPA')
            with tempfile.TemporaryDirectory(prefix='upload-', dir=service.incoming) as directory:
                ipa = Path(directory) / 'incoming.ipa'
                digest = hashlib.sha256()
                remaining = length
                with ipa.open('wb') as stream:
                    while remaining:
                        block = self.rfile.read(min(1024**2, remaining))
                        if not block:
                            raise UploadError(400, 'Incomplete IPA upload')
                        stream.write(block)
                        digest.update(block)
                        remaining -= len(block)
                checksum = digest.hexdigest()
                if expected and not hmac.compare_digest(expected, checksum):
                    raise UploadError(422, 'IPA SHA-256 does not match X-IPA-SHA256')
                status, receipt = service.publish(ipa, checksum, metadata)
                self.reply(status, receipt)
        except UploadError as error:
            self.reply(error.status, {'error': error.message})
        except (socket.timeout, TimeoutError):
            self.reply(408, {'error': 'Upload timed out'})
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            print(json.dumps({'event': 'upload_failed', 'errorType': type(error).__name__}), flush=True)
            self.reply(500, {'error': 'Upload failed; retry later'})
        finally:
            if acquired:
                service.slots.release()

    def do_GET(self):
        try:
            self.validate()
        except UploadError as error:
            self.reply(error.status, {'error': error.message})

    do_HEAD = do_GET
    do_PUT = do_GET
    do_DELETE = do_GET

    def log_message(self, fmt, *args):
        # No Authorization header, query string or uploaded content is logged.
        print(json.dumps({'method': self.command, 'path': urlsplit(self.path).path,
                          'event': 'http_request'}), flush=True)


def make_server(service, address=('127.0.0.1', 15007)):
    server = ThreadingHTTPServer(address, UploadHandler)
    server.service = service
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(REPO / 'hosting/home-source/source.config.json'))
    parser.add_argument('--token-file', default=str(Path.home() / '.config/yao-app-source/upload-token'))
    args = parser.parse_args()
    config = load_config(args.config)
    for key in ('root', 'publicRoot'):
        path = Path(config[key]).expanduser()
        config[key] = str(path if path.is_absolute() else REPO / path)
    token = Path(args.token_file).expanduser().read_text().strip()
    service = UploadService(config, token, REPO / 'distribution/app-source/assets/app-store-ios27.png')
    with make_server(service) as server:
        print('IPA upload backend listening on 127.0.0.1:15007', flush=True)
        server.serve_forever()


if __name__ == '__main__':
    main()
