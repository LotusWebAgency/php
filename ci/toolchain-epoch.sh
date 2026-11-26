#!/usr/bin/env bash
# Print the TOOLCHAIN_EPOCH build arg: the ISO week (YYYY-Www) of the current time
# minus 19h10, so the epoch turns over on Monday at 19:10 UTC rather than at midnight.
# The Dockerfile's toolchain-base stage (compile toolchain) is keyed on it, so the
# registry cache of the toolchain, ImageMagick and deps layers lives for one epoch
# and the build toolchain lags Wolfi by at most a week. The runtime stages are keyed
# on WOLFI_INDEX_STATE (ci/wolfi-index-state.sh) and stay current.
#
# TOOLCHAIN_EPOCH_OVERRIDE replaces the value, to force a toolchain refresh before
# the week ends (a library soname bump fails the runtime `apk add` until the
# toolchain is rebuilt). Use the current week with a revision suffix, for example
# 2026-W48.1; docker-bake.hcl's CACHE_WEEK is the value without the suffix.
set -euo pipefail

override="${TOOLCHAIN_EPOCH_OVERRIDE:-}"
if [ -n "$override" ]; then
  if ! [[ "$override" =~ ^([0-9]{4})-W([0-9]{2})(\.[0-9]+)?$ ]]; then
    echo "toolchain-epoch: TOOLCHAIN_EPOCH_OVERRIDE='$override' is not YYYY-Www or YYYY-Www.N" >&2
    exit 1
  fi
  week=$((10#${BASH_REMATCH[2]}))
  if [ "$week" -lt 1 ] || [ "$week" -gt 53 ]; then
    echo "toolchain-epoch: TOOLCHAIN_EPOCH_OVERRIDE='$override' has week $week; an ISO week is 01 to 53" >&2
    exit 1
  fi
  echo "$override"
else
  date -u -d "@$(( $(date -u +%s) - 69000 ))" +%G-W%V
fi
