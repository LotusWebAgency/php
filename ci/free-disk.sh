#!/usr/bin/env bash
# Free disk on a GitHub-hosted runner before pulling GBs of test images, and
# refuse to go on when too little is left.
#
#   [FREE_DISK_MIN_GB=20] ci/free-disk.sh
#   ci/free-disk.sh report
#
# On a GitHub-hosted runner (RUNNER_ENVIRONMENT=github-hosted; nothing is ever
# deleted anywhere else) removes toolchains this repo never uses from the root
# volume, which is also where /var/lib/docker lives: dotnet, the Android SDK,
# GHC and ghcup, Swift, and the hosted tool cache. The tool cache's Python is
# kept as a precaution (the scripts use the system python3, but that was not
# verified on a runner image), and the script fails when python3 stops
# working. Missing paths are skipped by rm -f. Then fails when free space on / is
# below FREE_DISK_MIN_GB (default 20) -- a pull that runs out of disk half way
# looks like a test failure, this does not.
#
# `report` only logs df and docker's usage; the workflow runs it at the end of
# every job, always, so the next run can be sized from real numbers.
set -euo pipefail

report() {
  df -h /
  docker system df 2>&1 || true
}

if [ "${1:-}" = report ]; then
  report
  exit 0
fi

min_gb="${FREE_DISK_MIN_GB:-20}"
free_gb() { df -BG --output=avail / | tail -1 | tr -dc '0-9'; }

echo "before:"
df -h / | tail -1
if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ]; then
  sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc /usr/local/.ghcup /usr/share/swift
  for d in /opt/hostedtoolcache/*; do
    [ -e "$d" ] || continue
    [ "$(basename "$d")" != Python ] || continue
    sudo rm -rf "$d"
  done
  python3 --version >/dev/null || { echo "FAIL: python3 is gone after freeing disk" >&2; exit 1; }
else
  echo "not a GitHub-hosted runner: nothing removed"
fi
echo "after:"
df -h / | tail -1

free="$(free_gb)"
if [ "$free" -lt "$min_gb" ]; then
  echo "FAIL: ${free} GB free on /, the jobs need at least ${min_gb} GB (FREE_DISK_MIN_GB). Not starting: a pull running out of disk would look like a test failure." >&2
  exit 1
fi
echo "ok: ${free} GB free on / (minimum ${min_gb})"
