#!/usr/bin/env python3
"""Manage the Cloudflare source without exposing management tokens in command output."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile
import time
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

REPO = Path(__file__).resolve().parents[1]
DEFAULT_CREDENTIALS = Path.home() / '.config/signos-source-aggregator/credentials.json'
DEFAULT_URL = 'https://signos-source-aggregator.305301890.workers.dev'
ARCHIVE = 'zh0ngtian/ipa-archive'


def credentials(path=DEFAULT_CREDENTIALS):
    value = json.loads(Path(path).expanduser().read_text())
    if not value['url'].startswith('https://') or not value['token']:
        raise ValueError('Invalid private source credentials')
    return value


class Client:
    def __init__(self, config):
        self.url, self.token = config['url'].rstrip('/'), config['token']

    def call(self, path, method='GET', body=None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
        request = Request(self.url + path, data=data, method=method, headers={
            'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json',
        })
        try:
            with urlopen(request, timeout=45) as response:
                return json.load(response)
        except HTTPError as error:
            reason = json.load(error).get('error', {})
            raise RuntimeError(f"{error.code}: {reason.get('code')} {reason.get('message')}") from None

    def state(self):
        return self.call('/api/catalog')

    def entry(self, entry_id):
        return next(x for x in self.state()['entries'] if x['id'] == entry_id)

    def create(self, config):
        result = self.call('/api/entries', 'POST', {'revision': self.state()['revision'], 'config': config})
        return result['entry']['id']

    def wait(self, entry_id, timeout=180):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            entry = self.entry(entry_id)
            if entry['status'] in ('ready', 'succeeded'):
                return entry
            if entry['status'] == 'failed':
                raise RuntimeError(json.dumps(entry['error'], ensure_ascii=False))
            time.sleep(1)
        raise TimeoutError('IPA parsing did not complete')

    def confirm(self, entry_id):
        return self.call(f'/api/entries/{entry_id}/confirm', 'POST', {'revision': self.state()['revision']})

    def attest(self, entry_id, digest):
        return self.call(f'/api/entries/{entry_id}/attest', 'POST', {'revision': self.state()['revision'], 'sha256': digest})


def gh(*args, json_result=False):
    result = subprocess.run(['gh', *args], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if json_result else result.stdout.strip()


def archive_asset(ipa, tag, name, digest, repository=ARCHIVE):
    """Upload immutable IPA bytes and require GitHub's full-file digest proof."""
    try:
        release = gh('api', f'repos/{repository}/releases/tags/{quote(tag, safe="")}', json_result=True)
    except subprocess.CalledProcessError:
        gh('release', 'create', tag, '--repo', repository, '--title', tag, '--notes', 'Archived build; original IPA bytes preserved.')
        release = gh('api', f'repos/{repository}/releases/tags/{quote(tag, safe="")}', json_result=True)
    asset = next((x for x in release['assets'] if x['name'] == name), None)
    if asset is None:
        gh('release', 'upload', tag, str(ipa) + '#' + name, '--repo', repository)
        release = gh('api', f'repos/{repository}/releases/tags/{quote(tag, safe="")}', json_result=True)
        asset = next(x for x in release['assets'] if x['name'] == name)
    if asset.get('digest') != 'sha256:' + digest or asset['size'] != Path(ipa).stat().st_size:
        raise ValueError('Existing GitHub IPA does not match the full-file SHA-256; nothing overwritten')
    return asset['browser_download_url']


def deploy(args):
    print(json.dumps({'worker': 'signos-source-aggregator', 'url': DEFAULT_URL, 'credentials': str(args.credentials), 'plan': args.plan}))
    if args.plan:
        return
    path = Path(args.credentials).expanduser()
    config = credentials(path) if path.exists() else {'url': DEFAULT_URL, 'token': secrets.token_urlsafe(48)}
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(config, indent=2) + '\n')
    path.chmod(0o600)
    worker = REPO / 'distribution/source-aggregator'
    subprocess.run(['npx', '--no-install', 'wrangler', 'deploy'], cwd=worker, check=True)
    # Secret content only exists in a mode-0600 temporary file and Wrangler's secret store.
    with tempfile.TemporaryDirectory(prefix='signos-worker-secrets-') as directory:
        secret_file = Path(directory) / 'secrets.json'
        secret_file.write_text(json.dumps({'ADMIN_TOKEN': config['token']}))
        secret_file.chmod(0o600)
        subprocess.run(['npx', '--no-install', 'wrangler', 'secret', 'bulk', str(secret_file)], cwd=worker, check=True)
    client = Client(config)
    state = client.state()
    print(json.dumps({'deployed': True, 'sourceURL': client.url + '/sources/yao.json', 'revision': state['revision']}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, default=DEFAULT_CREDENTIALS)
    commands = parser.add_subparsers(dest='command', required=True)
    deploy_parser = commands.add_parser('deploy')
    deploy_parser.add_argument('--plan', action='store_true')
    commands.add_parser('status')
    export_parser = commands.add_parser('export')
    export_parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'deploy':
        deploy(args)
    else:
        client = Client(credentials(args.credentials))
        if args.command == 'status':
            state = client.state()
            print(json.dumps({'revision': state['revision'], 'entries': [{'id': e['id'], 'name': (e['current'] or {}).get('metadata', {}).get('name'), 'status': e['status'], 'published': e['published'], 'error': e['error']} for e in state['entries']]}, ensure_ascii=False, indent=2))
        elif args.command == 'export':
            args.output.write_text(json.dumps(client.call('/api/export'), ensure_ascii=False, indent=2) + '\n')
            print(str(args.output.resolve()))


if __name__ == '__main__':
    main()
