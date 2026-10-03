#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'Sileo packaging requires macOS and Xcode.' >&2
    exit 1
fi

sileo_source_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$sileo_source_root"
mkdir -p .sileo-build/logs

# Procursus installs host header paths; they cannot be used for an iOS build.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH
export PATH="$(dirname "$(xcrun --find clang)"):$PATH"
export TMPDIR="${RUNNER_TEMP:?This CI script requires RUNNER_TEMP}/sileo-install-feedback/"
mkdir -p "$TMPDIR"

command -v ldid
command -v dpkg-deb
command -v make
dpkg-deb --version > .sileo-build/logs/dpkg-version.txt
make --version > .sileo-build/logs/make-version.txt
/opt/procursus/bin/dpkg-query -W -f='${Package}\t${Version}\n' ldid dpkg make xz-utils zstd \
    > .sileo-build/logs/host-packages.txt

python3 ci/test_installation_operations_cache.py \
    2>&1 | tee .sileo-build/logs/installation-operations-cache-tests.log

python3 ci/test_apt_pipe_actions.py \
    2>&1 | tee .sileo-build/logs/installation-pipe-actions-tests.log

python3 ci/test_installation_spawn_observation.py \
    2>&1 | tee .sileo-build/logs/installation-spawn-observation-tests.log

python3 - <<'PY'
import json
from pathlib import Path

root = Path.cwd()
project = root / 'Sileo.xcodeproj/project.pbxproj'
old_version = 'MARKETING_VERSION = "2.5.1-13";'
new_version = 'MARKETING_VERSION = "2.5.1-13+install-feedback.6";'
text = project.read_text()
if text.count(old_version) != 3:
    raise SystemExit('Unexpected Sileo project versions: refusing an imprecise replacement.')
project.write_text(text.replace(old_version, new_version))

# Use an isolated Makefile copy, leaving the source Makefile unchanged.
text = (root / 'Makefile').read_text()
if text.count('xcodebuild -jobs ') != 2:
    raise SystemExit('Unexpected build command: refusing an imprecise replacement.')
text = text.replace('xcodebuild -jobs ',
    'xcodebuild -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -jobs ')
(root / '.sileo-build/Makefile').write_text(text)

resolved = root / 'Sileo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
data = json.loads(resolved.read_text())
pins = data['object']['pins'] if data.get('version') == 1 else data['pins']
expected = sorted((p.get('repositoryURL', p.get('location')), p['state']['revision']) for p in pins)
if len(expected) != 11 or any(not revision for _, revision in expected):
    raise SystemExit('Unexpected or unpinned Swift dependency set.')
(root / '.sileo-build/logs/expected-package-pins.json').write_text(json.dumps(expected, indent=2) + '\n')
PY

plutil -lint Sileo.xcodeproj/project.pbxproj
xcodebuild -resolvePackageDependencies -project Sileo.xcodeproj -scheme Sileo \
    -onlyUsePackageVersionsFromResolvedFile -derivedDataPath "${TMPDIR}sileo" \
    2>&1 | tee .sileo-build/logs/package-resolution.log

# The locked Alderis dependency predates UIKit 18's UIViewController.tab property.
# Keep its dependency revision and fix only the conflicting internal field name.
python3 ci/apply_alderis_uikit18_compat.py "${TMPDIR}sileo/SourcePackages/checkouts/Alderis" \
    > .sileo-build/logs/alderis-uikit18-compat.json

python3 ci/normalize_device_link_stubs.py "$sileo_source_root" \
    > .sileo-build/logs/device-link-stubs.json

make -f .sileo-build/Makefile package SILEO_PLATFORM=iphoneos-arm64e \
    DEBUG=0 ALL_BOOTSTRAPS=1 BETA=0 NIGHTLY=0 V=1 \
    TARGET_CODESIGN="$(command -v ldid)" DPKG_TYPE=xz

python3 - <<'PY'
import json
import os
import plistlib
import subprocess
from pathlib import Path

root = Path.cwd()
resolved = root / 'Sileo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved'
data = json.loads(resolved.read_text())
pins = data['object']['pins'] if data.get('version') == 1 else data['pins']
actual = sorted((p.get('repositoryURL', p.get('location')), p['state']['revision']) for p in pins)
expected = json.loads((root / '.sileo-build/logs/expected-package-pins.json').read_text())
if actual != [tuple(p) for p in expected]:
    raise SystemExit('Swift dependency pins changed during the build.')
(root / '.sileo-build/logs/resolved-package-pins.json').write_text(json.dumps(actual, indent=2) + '\n')

packages = list((root / 'packages').glob('*.deb'))
if len(packages) != 1:
    raise SystemExit('Expected one independently built Sileo .deb.')
package = packages[0]
def field(name):
    return subprocess.check_output(['dpkg-deb', '-f', str(package), name], text=True).strip()

version = '2.5.1-13+install-feedback.6'
assert field('Package') == 'org.coolstar.sileo', 'Unexpected package ID'
assert field('Architecture') == 'iphoneos-arm64e', 'Unexpected package architecture'
assert field('Version') == version, 'Unexpected package version'
app = Path(os.environ['TMPDIR']) / 'sileo/stage/Applications/Sileo.app'
with (app / 'Info.plist').open('rb') as handle:
    info = plistlib.load(handle)
assert info['CFBundleShortVersionString'] == version, 'Bundle/control version mismatch'
assert info['CFBundleIdentifier'] == 'org.coolstar.SileoStore', 'Unexpected bundle ID'
subprocess.run(['xcrun', 'lipo', str(app / info['CFBundleExecutable']), '-verify_arch', 'arm64'], check=True)
subprocess.run(['dpkg-deb', '--info', str(package)], check=True,
    stdout=(root / '.sileo-build/logs/deb-control.txt').open('w'))
subprocess.run(['shasum', '-a', '256', str(package)], check=True,
    stdout=(root / '.sileo-build/logs/package-sha256.txt').open('w'))
PY
