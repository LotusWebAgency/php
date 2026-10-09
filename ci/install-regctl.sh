#!/usr/bin/env bash
# Install the pinned regctl (regclient) for this runner's architecture into
# $RUNNER_TEMP/bin and put it on the job's PATH.
#
#   ci/install-regctl.sh
#
# A release asset, checked against the sha256 recorded here; the sums were taken
# from the binaries after `cosign verify-blob` of their release sigstore bundles
# (identity: regclient's go.yml workflow at refs/tags/<version>). A bump changes
# all three lines together.
set -euo pipefail
version=v0.11.6
case "$(uname -m)" in
  x86_64) arch=amd64 sha=8e0e62a497fcdb8048d18aa927a139613176ba0531f412bc541044e28f9856bd ;;
  aarch64|arm64) arch=arm64 sha=a9b71a3ee79b2d1dbbd7d51fd5e8fa214722c192864235d3d8764463c751a1ff ;;
  *) echo "FAIL: no pinned regctl for $(uname -m)" >&2; exit 1 ;;
esac
dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/bin"
mkdir -p "$dir"
curl -fsSL --retry 5 -o "$dir/regctl" "https://github.com/regclient/regclient/releases/download/${version}/regctl-linux-${arch}"
echo "${sha}  $dir/regctl" | sha256sum -c --quiet - || { rm -f "$dir/regctl"; echo "FAIL: regctl ${version} checksum mismatch" >&2; exit 1; }
chmod +x "$dir/regctl"
echo "$dir" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
"$dir/regctl" version --format '{{.VCSTag}}'
