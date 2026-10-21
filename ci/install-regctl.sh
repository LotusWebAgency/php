#!/usr/bin/env bash
# Install the pinned regctl (regclient) for this runner's architecture into
# $RUNNER_TEMP/bin and put it on the job's PATH.
#
#   ci/install-regctl.sh
#
# A release asset, checked against the sha256 recorded here; the sums were taken
# from the binaries after `cosign verify-blob` of their release sigstore bundles
# (identity: regclient's go.yml workflow at refs/tags/<version>). A bump changes
# all three lines together. The download runs under ci/retry.sh (curl transfer
# errors, DNS failures, HTTP 5xx), which curl's own --retry does not cover.
set -euo pipefail
version=v0.11.7
case "$(uname -m)" in
  x86_64) arch=amd64 sha=3737fbbdd791e04e7a831640b681f3397a376498e80e2ad9b1b2d27296f239bc ;;
  aarch64|arm64) arch=arm64 sha=9f349bab5c407ac04f3dabf99c7c7a6b0f9e9723c23f2775380e804d02c6dbb9 ;;
  *) echo "FAIL: no pinned regctl for $(uname -m)" >&2; exit 1 ;;
esac
dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/bin"
mkdir -p "$dir"
RETRY_KIND=http "$(dirname "${BASH_SOURCE[0]}")/retry.sh" curl -fsSL -o "$dir/regctl" "https://github.com/regclient/regclient/releases/download/${version}/regctl-linux-${arch}"
echo "${sha}  $dir/regctl" | sha256sum -c --quiet - || { rm -f "$dir/regctl"; echo "FAIL: regctl ${version} checksum mismatch" >&2; exit 1; }
chmod +x "$dir/regctl"
echo "$dir" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
"$dir/regctl" version --format '{{.VCSTag}}'
