#!/usr/bin/env bash
# Route the runner daemon's Docker Hub pulls through mirror.gcr.io.
#
#   ci/hub-mirror.sh
#
# For the jobs that pull Docker Hub images through the daemon itself (`docker
# pull`, `docker run`, `docker build` with the docker driver): the corpus build,
# test-attest.sh's registries and the extended app stack. BuildKit in a
# docker-container builder does not read this; ci.yml gives it the same mirror
# plus public.ecr.aws/docker in buildkitd-config-inline.
#
# Every Docker Hub image this repository pulls is digest-pinned, so a mirror
# cannot change what is pulled -- the daemon checks the digest it gets. When the
# mirror lacks an image or errors, the daemon falls back to Docker Hub itself,
# anonymously: no job that pulls holds Docker Hub credentials (see ci.yml). The
# daemon's registry-mirrors cannot take public.ecr.aws (it serves Docker's
# official images under a path, docker/library/, and dockerd only accepts a mirror
# at a registry root), so its second source is Docker Hub, per runner IP.
set -euo pipefail
mirror="${HUB_MIRROR:-https://mirror.gcr.io}"
existing="$(cat /etc/docker/daemon.json 2>/dev/null || echo '{}')"
jq --argjson cur "$existing" --arg m "$mirror" -n '$cur + {"registry-mirrors": [$m]}' | sudo tee /etc/docker/daemon.json >/dev/null
sudo systemctl restart docker
docker info --format 'registry mirrors: {{.RegistryConfig.Mirrors}}'
