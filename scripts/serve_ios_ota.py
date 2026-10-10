#!/usr/bin/env python3
"""Serve SignOs's isolated OTA channel using the shared LAN TLS certificate.

The allowlisted HTTP handler comes from the installed ios-adhoc-ota skill.
Private configuration and signing material remain outside this repository.
"""
import argparse
import importlib.util
import json
from http.server import ThreadingHTTPServer
from pathlib import Path
import ssl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    args = parser.parse_args()
    config = json.loads(Path(args.config).expanduser().read_text())
    source = Path(config['skillDir']).expanduser() / 'scripts/ios_ota_server.py'
    spec = importlib.util.spec_from_file_location('ota_server', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    server = ThreadingHTTPServer(('0.0.0.0', config['httpsPort']), module.handler(config))
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(config['tlsCertificate'], config['tlsKey'])
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    server.serve_forever()


if __name__ == '__main__':
    main()
