#!/usr/bin/env python3
"""Install the local, persistent IPA upload backend behind Nginx."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys

from source_config import load_config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', action='store_true')
    args = parser.parse_args()
    private = Path.home() / '.config/yao-app-source'
    token = private / 'upload-token'
    label = 'local.yao-app-source.upload'
    target = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
    document = {
        'Label': label,
        'ProgramArguments': [sys.executable, '-B', str(Path(__file__).with_name('home_upload.py').resolve()),
                             '--token-file', str(token)],
        'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
        'WorkingDirectory': str(Path(__file__).resolve().parents[1]),
        'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
        'StandardOutPath': str(private / 'upload.log'),
        'StandardErrorPath': str(private / 'upload.log'),
    }
    if args.plan:
        print(json.dumps({'job': document, 'tokenFile': str(token),
                          'createToken': not token.exists()}, indent=2))
        return
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not token.exists():
        fd = os.open(token, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as stream:
            stream.write(secrets.token_urlsafe(32) + '\n')
    token.chmod(0o600)
    # Validate configuration before replacing the running launchd job.
    from home_upload import UploadService, REPO
    config = load_config(REPO / 'hosting/home-source/source.config.json')
    for key in ('root', 'publicRoot'):
        config[key] = str(REPO / config[key])
    UploadService(config, token.read_text().strip(), REPO / 'distribution/app-source/assets/app-store-ios27.png')
    service = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', service + '/' + label], capture_output=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(plistlib.dumps(document))
    subprocess.run(['launchctl', 'bootstrap', service, str(target)], check=True)
    print('Installed:', target)
    print('Token saved to:', token, '(0600; value is never printed)')


if __name__ == '__main__':
    main()
