#!/usr/bin/env python3
"""Upload an unchanged IPA to the home source using its shared Bearer token."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import ssl
from urllib.parse import urlencode, urlsplit

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True)
    parser.add_argument('--url', help='HTTPS upload endpoint; otherwise use APP_SOURCE_BASE_URL + /api/upload')
    parser.add_argument('--token-file', help='UTF-8 file containing the shared token')
    parser.add_argument('--developer')
    parser.add_argument('--description')
    parser.add_argument('--notes')
    parser.add_argument('--plan', action='store_true', help='Calculate size/SHA-256 without reading a token or uploading')
    args = parser.parse_args()
    args.url = args.url or (os.environ['APP_SOURCE_BASE_URL'].rstrip('/') + '/api/upload'
                            if os.environ.get('APP_SOURCE_BASE_URL') else None)
    if not args.url:
        raise SystemExit('Set APP_SOURCE_BASE_URL in your private environment or provide --url')
    path = Path(args.ipa).expanduser().resolve(strict=True)
    size = path.stat().st_size
    if not 0 < size <= 2 * 1024**3:
        raise SystemExit('IPA must be non-empty and no larger than 2 GiB')
    with path.open('rb') as stream:
        checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
    url = urlsplit(args.url)
    if url.scheme != 'https' or url.username or url.password or url.query or url.fragment or not url.hostname:
        raise SystemExit('Upload URL must be HTTPS without credentials, query or fragment')
    metadata = {k: getattr(args, k) for k in ('developer', 'description', 'notes') if getattr(args, k) is not None}
    if any(len(v) > 2000 for v in metadata.values()):
        raise SystemExit('Each metadata field must be no longer than 2000 characters')
    query = urlencode(metadata)
    if len(query) > 8192:
        raise SystemExit('URL-encoded metadata must be no longer than 8 KiB')
    if args.plan:
        print(json.dumps({'url': args.url, 'size': size, 'sha256': checksum, 'metadata': metadata,
                          'plan': True}, ensure_ascii=False, indent=2))
        return
    token = (Path(args.token_file).expanduser().read_text().strip() if args.token_file
             else os.environ.get('APP_SOURCE_UPLOAD_TOKEN', '').strip())
    if len(token) < 32 or any(c.isspace() for c in token):
        raise SystemExit('Provide --token-file or APP_SOURCE_UPLOAD_TOKEN containing the shared token')
    target = (url.path or '/') + ('?' + query if query else '')
    connection = http.client.HTTPSConnection(url.hostname, url.port or 443, timeout=900,
                                             context=ssl.create_default_context())
    try:
        connection.putrequest('POST', target)
        connection.putheader('Authorization', 'Bearer ' + token)
        connection.putheader('Content-Type', 'application/octet-stream')
        connection.putheader('Content-Length', str(size))
        connection.putheader('X-IPA-SHA256', checksum)
        connection.endheaders()
        with path.open('rb') as stream:
            while block := stream.read(1024**2):
                connection.send(block)
        response = connection.getresponse()
        data = response.read(1024**2)
        try:
            result = json.loads(data)
        except ValueError:
            raise SystemExit(f'Upload failed: HTTP {response.status}, non-JSON response') from None
        print(json.dumps(result, ensure_ascii=False, indent=2))
        if response.status not in (200, 201):
            raise SystemExit(f'Upload failed: HTTP {response.status}')
        if result.get('sha256') != checksum or result.get('size') != size:
            raise SystemExit('Upload response does not match the local IPA')
    except (OSError, http.client.HTTPException) as error:
        raise SystemExit('Upload connection failed: ' + str(error)) from None
    finally:
        connection.close()


if __name__ == '__main__':
    main()
