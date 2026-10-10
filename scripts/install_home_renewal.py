#!/usr/bin/env python3
"""Install the local launchd certificate renewal job (12-hour checks)."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--plan', action='store_true')
args = parser.parse_args()
private = Path.home() / '.config/yao-app-source'
config = private / 'renewal.json'
if not config.is_file():
    raise SystemExit('Configure ~/.config/yao-app-source/renewal.json first')
label = 'local.yao-app-source.renew-tls'
target = Path.home() / 'Library/LaunchAgents' / (label + '.plist')
document = {
    'Label': label,
    'ProgramArguments': [sys.executable, '-B', str(Path(__file__).with_name('renew_home_tls.py').resolve()),
                         '--config', str(config)],
    'EnvironmentVariables': {'PATH': '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'},
    'RunAtLoad': True,
    'StartInterval': 43200,
    'KeepAlive': {'SuccessfulExit': False},
    'ThrottleInterval': 3600,
    'StandardOutPath': str(private / 'renewal.log'),
    'StandardErrorPath': str(private / 'renewal.log'),
}
if args.plan:
    print(json.dumps(document, indent=2))
else:
    service = 'gui/' + str(os.getuid())
    subprocess.run(['launchctl', 'bootout', service + '/' + label], capture_output=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(plistlib.dumps(document))
    subprocess.run(['launchctl', 'bootstrap', service, str(target)], check=True)
    print('Installed:', target)
