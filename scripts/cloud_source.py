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
            'Authorization': 'Bearer ' + self.token, 'Content-Type': 'application/json', 'User-Agent': 'SignOs-Publisher/1',
        })
        try:
            with urlopen(request, timeout=45) as response:
                return json.load(response)
        except HTTPError as error:
            raw = error.read()
            try:
                reason = json.loads(raw).get('error', {})
            except (ValueError, AttributeError):
                reason = {'code': 'UPSTREAM_HTTP_ERROR', 'message': '服务返回非 JSON 响应'}
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


def publish_signos(args, receipt, config):
    """Publish the same formally signed OTA IPA through GitHub-backed Cloudflare."""
    client = Client(credentials(config.get('credentialsFile', DEFAULT_CREDENTIALS)))
    repository = config.get('archiveRepository', ARCHIVE)
    tag = f"signos/v{receipt['version']}-{receipt['buildNumber']}"
    download = archive_asset(args.ipa, tag, 'SignOs.ipa', receipt['sha256'], repository)
    subscription = {'kind': 'github', 'repository': repository, 'tagPrefix': 'signos/', 'assetPattern': 'SignOs.ipa', 'includePrereleases': False}
    existing = next((e for e in client.state()['entries'] if all(e['config'].get(k) == v for k, v in subscription.items())), None)
    entry_id = existing['id'] if existing else client.create(subscription)
    if existing:
        client.call(f'/api/entries/{entry_id}/sync', 'POST', {})
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        entry = client.entry(entry_id)
        current = entry['current']
        if entry['status'] == 'failed':
            raise RuntimeError(json.dumps(entry['error'], ensure_ascii=False))
        if current and current['downloadURL'] == download and entry['status'] in ('ready', 'succeeded'):
            break
        time.sleep(1)
    else:
        raise TimeoutError('New signed SignOs IPA did not reach the source')
    actual = current['metadata']
    if (actual['bundleIdentifier'], actual['version'], actual['buildVersion']) != (receipt['bundleId'], receipt['version'], receipt['buildNumber']):
        raise ValueError('Cloudflare parsing differs from signed OTA receipt')
    if not entry['published']:
        client.confirm(entry_id)
    client.attest(entry_id, receipt['sha256'])
    digest, count = hashlib.sha256(), 0
    with urlopen(Request(download, headers={'User-Agent': 'SignOs-Publisher/1'}), timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk); count += len(chunk)
    if digest.hexdigest() != receipt['sha256'] or count != receipt['size']:
        raise ValueError('Public GitHub IPA differs from signed OTA package')
    source_url = client.url + '/sources/yao.json'
    with urlopen(Request(source_url, headers={'User-Agent': 'SignOs-Publisher/1'}), timeout=30) as response:
        document = json.load(response)
    app = next(a for a in document['apps'] if a.get('appID') == entry_id)
    if (app['version'], app['buildVersion'], app['downloadURL'], app['sha256'], app['size']) != (receipt['version'], receipt['buildNumber'], download, receipt['sha256'], receipt['size']):
        raise ValueError('Public source JSON differs from OTA receipt')
    print(json.dumps({'published': True, 'sourceURL': source_url, 'downloadURL': download, 'version': receipt['version'], 'buildNumber': receipt['buildNumber'], 'sha256': receipt['sha256'], 'size': receipt['size']}, ensure_ascii=False, indent=2))


def configure_github():
    """Requires explicit authorization to transfer the local GitHub credential."""
    with tempfile.TemporaryDirectory(prefix='signos-github-secret-') as directory:
        secret_file = Path(directory) / 'github.json'
        secret_file.write_text(json.dumps({'GITHUB_TOKEN': gh('auth', 'token')}))
        secret_file.chmod(0o600)
        subprocess.run(['npx', '--no-install', 'wrangler', 'secret', 'bulk', str(secret_file)], cwd=REPO / 'distribution/source-aggregator', check=True)
    print('GitHub Token 已保存到 Worker Secret；未输出凭据。')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials', type=Path, default=DEFAULT_CREDENTIALS)
    commands = parser.add_subparsers(dest='command', required=True)
    deploy_parser = commands.add_parser('deploy')
    deploy_parser.add_argument('--plan', action='store_true')
    commands.add_parser('status')
    commands.add_parser('configure-github', help='Explicitly authorized upload of the local GitHub token to Worker Secret')
    export_parser = commands.add_parser('export')
    export_parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'configure-github':
        configure_github()
    elif args.command == 'deploy':
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
