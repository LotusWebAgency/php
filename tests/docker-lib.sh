# shellcheck shell=bash
# Sourced by the smoke-family scripts (smoke.sh, test-pgo.sh, test-readonly.sh,
# test-entrypoint.sh, test-fpm-health.sh, test-uarch.sh).
#
#   drun <docker run args>   docker run with no network and no implicit pull
#   DRUN_FLAGS               those flags, for the one call that cannot be a function
#                            (`timeout N docker run "${DRUN_FLAGS[@]}" ...`)
#
# These suites test an image that is already in the local daemon, so a run that
# reaches the registry or the internet is a test that can flake on the network
# and say nothing about the image. --pull never turns a missing image into an
# immediate error instead of a silent pull of whatever the tag points at today;
# --network none leaves only loopback, which is all the checks that bind a
# socket inside the container (php-fpm on 127.0.0.1:9000, cgi-fcgi) need.
# Anything that publishes a port or talks to another container (the TLS block
# in smoke.sh, test-snuffleupagus.sh) keeps plain `docker run`.
DRUN_FLAGS=(--pull never --network none)
#
# The docker client copies a container's stdout and stderr concurrently, so a
# caller's `out=$(drun ... 2>&1)` can splice a stderr warning into the middle of
# a stdout line and break the exact-line greps the suites rely on. When both
# streams go to the same pipe or file, drun holds stderr back and appends it
# after the container exits.
drun() {
  if [ -t 1 ] || [ ! /dev/stdout -ef /dev/stderr ]; then
    docker run "${DRUN_FLAGS[@]}" "$@"
    return
  fi
  local errf rc=0
  errf=$(mktemp)
  docker run "${DRUN_FLAGS[@]}" "$@" 2>"$errf" || rc=$?
  cat "$errf" >&2
  rm -f "$errf"
  return "$rc"
}
