#!/usr/bin/env python3
"""Apply the reviewed RootHide XPF additions to the pinned Dopamine 3 XPF."""

import json
from pathlib import Path
import subprocess


def main():
    root = Path(__file__).resolve().parents[1]
    lock = json.loads((root / '.ci/dependencies.json').read_text(encoding='utf-8'))
    xpf = root / 'BaseBin/XPF'
    patch = root / 'patches/xpf-roothide.patch'
    actual = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=xpf, text=True).strip()
    if actual != lock['xpf_base']:
        raise SystemExit(f'Unexpected XPF revision: {actual}; expected {lock["xpf_base"]}')

    command = ['git', 'apply', '--check', str(patch)]
    pending = subprocess.run(command, cwd=xpf, capture_output=True, text=True)
    if pending.returncode == 0:
        subprocess.run(['git', 'apply', str(patch)], cwd=xpf, check=True)
        print('Applied the RootHide XPF port patch.')
        return

    applied = subprocess.run(['git', 'apply', '--reverse', '--check', str(patch)],
                             cwd=xpf, capture_output=True, text=True)
    if applied.returncode != 0:
        raise SystemExit('XPF does not match either the clean base or the reviewed patch.\n'
                         + pending.stderr + applied.stderr)
    print('RootHide XPF port patch is already applied.')


if __name__ == '__main__':
    main()
