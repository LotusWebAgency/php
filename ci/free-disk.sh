#!/usr/bin/env bash
# Free disk on a GitHub-hosted runner before pulling GBs of test images.
#
#   ci/free-disk.sh
#
# Removes toolchains this repo never uses (dotnet, Android SDK, GHC, CodeQL
# bundles) from the runner's root volume, which is also where /var/lib/docker
# lives. Paths that do not exist on the runner image (the arm64 one) are
# skipped by rm -f.
set -euo pipefail
df -h / | tail -1
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /opt/hostedtoolcache/CodeQL
df -h / | tail -1
