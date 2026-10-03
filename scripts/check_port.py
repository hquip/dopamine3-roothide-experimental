#!/usr/bin/env python3
"""Host-side integration checks; these do not establish device compatibility."""

import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parents[1]
    listed = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root)
    errors = []
    checked = 0
    for name in sorted(set(listed.decode('utf-8').split('\0'))):
        path = root / name
        if not name or not path.is_file() or path.is_symlink():
            continue
        content = path.read_bytes()
        if path.suffix in ('.plist', '.entitlements'):
            try:
                plistlib.loads(content)
            except Exception as error:
                errors.append(f'{name}: invalid property list: {error}')
        elif path.suffix == '.json':
            try:
                json.loads(content)
            except Exception as error:
                errors.append(f'{name}: invalid JSON: {error}')
        if b'\0' not in content:
            text = content.decode('utf-8', errors='replace')
            for number, line in enumerate(text.splitlines(), 1):
                if re.match(r'^(<<<<<<< |>>>>>>> |\|{7} )', line):
                    errors.append(f'{name}:{number}: unresolved merge marker')
        checked += 1

    header = (root / 'BaseBin/libjailbreak/src/jbserver_domains.h').read_text()
    domains = re.findall(r'^#define\s+(JBS_DOMAIN_\w+)\s+(\d+)\b', header, re.M)
    values = [value for _, value in domains]
    if len(values) != len(set(values)):
        errors.append('Duplicate jailbreak service domain IDs.')

    version = (root / 'BaseBin/_external/basebin/.version').read_text().strip()
    if not re.fullmatch(r'3\.0\.10-roothide-port\.\d+', version):
        errors.append('Missing experimental port version identifier.')
    app_info = plistlib.loads((root / 'Application/Dopamine/Info.plist').read_bytes())
    runtime_version = app_info.get('DORootHideRuntimeVersion')
    if runtime_version is not None and runtime_version != version:
        errors.append('The app-required runtime version must match the bundled basebin.')

    # These are reviewed RootHide resources, not the ordinary
    # Procursus iOS bootstrap downloaded by the original Dopamine workflow.
    resources = root / 'Application/Dopamine/Resources'
    resource_hashes = {
        'bootstrap_1800.tar.zst': '3350ed91d77163e0cd73f0f90185b5c9b87d9d294133e25ced3a29329e90370e',
        'bootstrap_1900.tar.zst': '420f72d1a62c9f884733cdefc596728469482a48858ec7ceca4d3ab2d3cba56c',
        'roothideapp.deb': 'b8f075e1844709845962900b22fe71136a66369a2c35bb1201087f2fd9476b7d',
        # Reviewed Sileo 2.5.1-13+install-feedback.6, passive diagnostic consumer.
        'sileo.deb': 'c09b29f4f1a3bc81c706c6c9a42720876472e108a13b9e2fd8a41878287d824e',
        # RootHide tag27 Zebra resource for iphoneos-arm64e.
        'zebra.deb': 'ca82c18256e19ff78af3e53308d53f047a2d429cb7e025c892377abe4d2e7825',
    }
    for name, expected in resource_hashes.items():
        path = resources / name
        if not path.is_file():
            errors.append(f'Missing reviewed RootHide resource: {name}')
        elif hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            errors.append(f'Unexpected RootHide resource content: {name}; review its provenance before updating the hash.')
    if (resources / 'download_bootstraps.sh').exists():
        errors.append('The ordinary Dopamine bootstrap downloader must not replace the bundled RootHide resources.')

    if errors:
        print('\n'.join(errors), file=sys.stderr)
        raise SystemExit(1)
    print(f'Checked {checked} files: no merge markers, malformed plists/JSON, or duplicate domain IDs.')
    print('Reviewed RootHide bootstrap and manager resource hashes match.')
    print('This is a source integration check, not an iOS build or a device test.')


if __name__ == '__main__':
    main()
