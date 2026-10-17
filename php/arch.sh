#!/usr/bin/env bash
# Print the image architecture name (amd64 or arm64) for the machine running the build.
# uname is the authority, not a package manager. An unmapped machine fails loudly.
set -euo pipefail

case "$(uname -m)" in
  x86_64)  echo amd64 ;;
  aarch64) echo arm64 ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac
