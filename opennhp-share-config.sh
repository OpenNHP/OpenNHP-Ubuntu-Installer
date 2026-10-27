#!/usr/bin/env bash
# Export public connection details and a key-free QuickChart QR image link.
set -Eeuo pipefail
umask 077
command -v python3 >/dev/null || { printf 'Error: python3 is required.\n' >&2; exit 1; }
exec python3 - "$@" <<'PY'
import argparse
import base64
import datetime
import json
import os
from pathlib import Path
import re
import secrets
import sys
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser(description='Export OpenNHP public connection settings and a QuickChart QR link. No API key required.')
parser.add_argument('--root', default=os.environ.get('NHP_ROOT', '/opt/opennhp'), help='OpenNHP install directory (default: NHP_ROOT or /opt/opennhp)')
parser.add_argument('--output-dir', help='New directory for the export; must not already exist')
parser.add_argument('--auth-service', default='example', help='Auth service ID (default: example)')
parser.add_argument('--resource', default='web', help='Resource ID (default: web)')
parser.add_argument('--download-qr', action='store_true', help='Also contact QuickChart now to save qr.png; sends public connection details to QuickChart')
args = parser.parse_args()


def main():
    root = Path(args.root)
    config_path = root / 'source/release/nhp-server/etc/config.toml'
    text = config_path.read_text(encoding='utf-8')
    # Read only the installer-generated top-level scalars. This also works with
    # Ubuntu 22.04's Python 3.10, which does not include tomllib.
    top_level = re.split(r'^\s*\[', text, maxsplit=1, flags=re.M)[0]

    def scalar(name, pattern):
        values = re.findall(r'^\s*' + re.escape(name) + r'\s*=\s*(' + pattern + r')\s*(?:#.*)?$', top_level, re.M)
        if len(values) != 1:
            raise ValueError(f'Expected one {name} in {config_path}')
        return values[0]

    host = scalar('Hostname', r'"[a-zA-Z0-9.-]+"')[1:-1]
    if len(host) > 253 or not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?', host):
        raise ValueError('Invalid server hostname')
    if host in ('0.0.0.0', 'localhost') or host.startswith('127.'):
        raise ValueError('Server Hostname must be an address reachable by agents')
    port = int(scalar('ListenPort', r'[0-9]+'))
    if not 1 <= port <= 65535:
        raise ValueError('ListenPort must be between 1 and 65535')
    with (root / 'secrets/server.json').open(encoding='utf-8') as handle:
        public_key = json.load(handle)['publicKey']
    if not isinstance(public_key, str) or len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('Expected a base64-encoded 32-byte server public key')
    for value in (args.auth_service, args.resource):
        if not re.fullmatch(r'[a-zA-Z0-9_.-]{1,64}', value):
            raise ValueError('Auth service and resource IDs must be 1-64 letters, digits, dots, underscores or hyphens')

    # Explicit allowlist: never serialize server/agent private keys or the source
    # config wholesale, even if new fields are added to those files later.
    profile = {'schemaVersion': 1, 'host': host, 'port': port,
               'serverPublicKey': public_key, 'authServiceId': args.auth_service,
               'resourceId': args.resource}
    payload = json.dumps(profile, separators=(',', ':'), ensure_ascii=True)
    qr_url = 'https://quickchart.io/qr?' + urllib.parse.urlencode(
        {'text': payload, 'size': 600, 'margin': 4, 'ecLevel': 'M', 'format': 'png'})
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    output = Path(args.output_dir) if args.output_dir else root / 'shares' / f'{stamp}-{secrets.token_hex(4)}'
    # Refuse existing directories so old exports and symlinks cannot be overwritten.
    if not args.output_dir:
        output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    output.mkdir(mode=0o700)
    (output / 'connection.json').write_text(json.dumps(profile, indent=2) + '\n', encoding='utf-8')
    (output / 'qr-link.txt').write_text(qr_url + '\n', encoding='utf-8')
    print(f'Connection JSON: {output / "connection.json"}')
    print(f'QR image link (share with trusted users):\n{qr_url}')
    print('The QR contains the JSON connection settings; it does not grant device trust.')
    print('Opening the link sends these public connection details to QuickChart.')
    if args.download_qr:
        request = urllib.request.Request(qr_url, headers={'User-Agent': 'OpenNHP-Share-Config/1'})
        with urllib.request.urlopen(request, timeout=30) as response:
            png = response.read(2_000_001)
        if not png.startswith(b'\x89PNG\r\n\x1a\n') or len(png) > 2_000_000:
            raise ValueError('QuickChart did not return a valid-sized PNG; JSON and link remain available')
        (output / 'qr.png').write_bytes(png)
        print(f'QR image: {output / "qr.png"}')


try:
    main()
except (OSError, ValueError, KeyError, TypeError) as exc:
    print(f'Error: {exc}', file=sys.stderr)
    sys.exit(1)
PY
