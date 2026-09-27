#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo "This build setup requires macOS and Xcode." >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "The experimental CI build expects a native arm64 macOS runner." >&2
    exit 1
fi

# Host package headers and libraries must not leak into iOS cross-compilation.
unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-path

port_root="$(cd "$(dirname "$0")/.." && pwd)"
port_work="$port_root/.port-build"
port_lock="$port_root/.ci/dependencies.json"
mkdir -p "$port_work/logs"

lock_value() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$port_lock" "$1"
}

clone_pinned() {
    local repository="$1" revision="$2" destination="$3"
    if [[ ! -d "$destination/.git" ]]; then
        git init "$destination"
        git -C "$destination" remote add origin "$repository"
    fi
    if [[ "$(git -C "$destination" remote get-url origin)" != "$repository" ]]; then
        echo "Unexpected dependency repository at $destination" >&2
        exit 1
    fi
    git -C "$destination" fetch --depth=1 origin "$revision"
    git -C "$destination" checkout --detach "$revision"
    git -C "$destination" submodule update --init --recursive
}

brew install make libarchive openssl@3 xz
export PATH="$(brew --prefix make)/libexec/gnubin:$PATH"
export THEOS="$port_work/theos"
clone_pinned https://github.com/roothide/theos.git "$(lock_value theos_commit)" "$THEOS"

port_sdk_archive="$port_work/iPhoneOS16.5.sdk.tar.xz"
curl --fail --location --retry 3 "$(lock_value sdk_url)" --output "$port_sdk_archive"
printf '%s  %s\n' "$(lock_value sdk_sha256)" "$port_sdk_archive" | shasum -a 256 --check
mkdir -p "$THEOS/sdks"
tar -xJf "$port_sdk_archive" -C "$THEOS/sdks"
test -d "$THEOS/sdks/iPhoneOS16.5.sdk"
test -f "$THEOS/sdks/iPhoneOS16.5.sdk/SDKSettings.plist"

clone_pinned https://github.com/CRKatri/trustcache.git "$(lock_value trustcache_commit)" "$port_work/trustcache"
port_openssl="$(brew --prefix openssl@3)"
port_arch="$(uname -m)"
CFLAGS="${CFLAGS:-} -I$port_openssl/include -arch $port_arch" \
LDFLAGS="${LDFLAGS:-} -L$port_openssl/lib -arch $port_arch" \
    gmake -C "$port_work/trustcache" -j"$(sysctl -n hw.logicalcpu)" OPENSSL=1 CC="$(xcrun --find clang)"
sudo install -m 755 "$port_work/trustcache/trustcache" /opt/procursus/bin/trustcache

# Exercise the exact packaging options used by Packages/* before compiling.
port_probe="$(mktemp -d "$port_work/package-probe.XXXXXX")"
mkdir -p "$port_probe/package/DEBIAN"
printf 'Package: roothide-port-build-probe\nVersion: 1\nArchitecture: all\nMaintainer: Build probe\nDescription: Packaging capability check\n' > "$port_probe/package/DEBIAN/control"
dpkg-deb --root-owner-group -Zzstd --build "$port_probe/package" "$port_probe/probe.deb"
dpkg-deb --info "$port_probe/probe.deb" > "$port_work/logs/dpkg-probe.txt"
dpkg-query --show > "$port_work/logs/procursus-packages.txt"
file "$(command -v ldid)" "$(command -v dpkg-deb)" /opt/procursus/bin/trustcache > "$port_work/logs/host-tools.txt"

git -C "$THEOS" rev-parse HEAD > "$port_work/logs/theos-commit.txt"
git -C "$THEOS" submodule status --recursive > "$port_work/logs/theos-submodules.txt"
git -C "$port_work/trustcache" rev-parse HEAD > "$port_work/logs/trustcache-commit.txt"
brew list --versions > "$port_work/logs/homebrew-versions.txt"
