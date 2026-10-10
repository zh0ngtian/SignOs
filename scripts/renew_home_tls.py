#!/usr/bin/env python3
"""Renew the home source's public certificate with DNS-01 and reload Nginx."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import json
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import time
from urllib.parse import urlsplit


def command(config, root, staging=False):
    args = [config['docker'], 'run', '--rm', '--env-file', config['credentials'],
            '-e', 'TENCENTCLOUD_PROPAGATION_TIMEOUT=180',
            '-v', str(root) + ':/acme', config['image'], 'run', '--path', '/acme',
            '--email', config['email'], '--accept-tos', '--dns', 'tencentcloud',
            '--dns.resolvers', '223.5.5.5:53', '--dns.resolvers', '1.1.1.1:53',
            '--dns.propagation.disable-rns',
            '--domains', config['domain'], '--renew-days', '30', '--no-random-sleep']
    if config.get('propagationWait'):
        args += ['--dns.propagation.wait', config['propagationWait']]
    if staging:
        args += ['--server', 'letsencrypt-staging', '--renew-force']
    return args


def fingerprint(path):
    first = path.read_text().split('-----END CERTIFICATE-----')[0] + '-----END CERTIFICATE-----\n'
    return hashlib.sha256(ssl.PEM_cert_to_DER_cert(first)).hexdigest()


def peer(config):
    url = urlsplit(config['probeUrl'])
    context = ssl.create_default_context()
    with socket.create_connection((url.hostname, url.port or 443), timeout=15) as connection:
        with context.wrap_socket(connection, server_hostname=url.hostname) as secured:
            return hashlib.sha256(secured.getpeercert(binary_form=True)).hexdigest(), secured.getpeercert()['notAfter']


def run(config, staging=False, issue_only=False):
    root = Path(config['acmeRoot']).expanduser()
    if staging:
        root = root.with_name(root.name + '-staging')
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (root / '.renew.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        certificate = root / 'certificates' / (config['domain'] + '.crt')
        if certificate.exists():
            backup = root / 'backups' / fingerprint(certificate)
            if not backup.exists():
                backup.mkdir(parents=True, mode=0o700)
                for path in certificate.parent.glob(config['domain'] + '.*'):
                    shutil.copy2(path, backup / path.name)
        subprocess.run(command(config, root, staging), check=True, timeout=900)
        if staging or issue_only:
            return {'staging': staging, 'certificate': str(certificate), 'sha256': fingerprint(certificate)}
        expected = fingerprint(certificate)
        # Always retry a pending reload after a previous failure, even if lego skipped renewal.
        try:
            current, expires = peer(config)
        except (OSError, ssl.SSLError):
            current = None
        if current != expected:
            subprocess.run([config['docker'], 'exec', config['container'], 'nginx', '-t'], check=True)
            subprocess.run([config['docker'], 'exec', config['container'], 'nginx', '-s', 'reload'], check=True)
            for _ in range(10):
                current, expires = peer(config)
                if current == expected:
                    break
                time.sleep(1)
            if current != expected:
                raise ValueError('Nginx did not serve the renewed certificate')
        return {'staging': False, 'sha256': expected, 'notAfter': expires, 'tlsVerified': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(Path.home() / '.config/yao-app-source/renewal.json'))
    parser.add_argument('--staging-test', action='store_true')
    parser.add_argument('--issue-only', action='store_true')
    args = parser.parse_args()
    config_path = Path(args.config).expanduser()
    config = json.loads(config_path.read_text())
    try:
        result = run(config, args.staging_test, args.issue_only)
        result.update(success=True, checkedAt=datetime.now(timezone.utc).isoformat())
    except Exception as error:
        result = {'success': False, 'checkedAt': datetime.now(timezone.utc).isoformat(), 'error': str(error)}
        raise
    finally:
        name = 'renewal-staging-status.json' if args.staging_test else 'renewal-status.json'
        (config_path.parent / name).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
