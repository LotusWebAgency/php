#!/bin/sh
# Build the fixture the way the README tells people to build their own
# extension, installing under the given root: build.sh <install-root>.
# Works on a copy, so running it against a read-only mount leaves nothing behind.
set -eu
root="${1:?usage: build.sh <install-root>}"
src="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
cp -R "$src"/. "$work"
cd "$work"
phpize
./configure --enable-hello
make -j"$(nproc)"
make install INSTALL_ROOT="$root"
