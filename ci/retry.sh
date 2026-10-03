#!/usr/bin/env bash
# Run a command, retrying it with backoff when it fails the way a busy registry
# fails, and only then.
#
#   ci/retry.sh <command> [args...]
#
# Docker Hub answers a burst of concurrent CI legs with `429 Too Many Requests`
# (and now and then a 5xx or a dropped connection). A personal account's pull
# limit is counted per hour, and one warm-cache publish run reads several
# hundred manifests in minutes, so the waits run long: a failure that matches
# the pattern below is retried after 30, 60, 120, 300, 600, 900 seconds (plus
# up to 50% jitter, so 100 legs do not come back in lockstep) -- seven attempts
# over half an hour or more. Anything else -- a missing image, a denied
# login, a failing build -- exits at once with the command's own exit code, and
# the command's output is passed through either way.
#
#   RETRY_DELAYS    seconds to wait before retry 1, 2, ... (default "30 60 120 300 600 900");
#                   the last one repeats if RETRY_ATTEMPTS asks for more attempts
#   RETRY_ATTEMPTS  attempts in total (default: one more than RETRY_DELAYS has entries)
#
# Only the command's stderr is matched (that is where docker, buildx and cosign
# print registry errors). Its stdout is passed straight through and never
# buffered, so a long `docker buildx bake` still streams -- which also means a
# failed attempt's stdout is not discarded: wrap commands that print their result
# on success only (`imagetools inspect --raw`, `docker pull`), not ones that
# print and then fail.
#
# Retried commands must be safe to run again; the callers decide that
# (see the comments at each call site).
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }

read -ra delays <<<"${RETRY_DELAYS:-30 60 120 300 600 900}"
[ "${#delays[@]}" -gt 0 ] || delays=(0)
max="${RETRY_ATTEMPTS:-$((${#delays[@]} + 1))}"

transient='too many requests|toomanyrequests'
transient+='|(unexpected status|status code|http status)[^[:cntrl:]]*[ :]5[0-9][0-9]( |$)'
transient+='|\]\[5[0-9][0-9]\]'
transient+='|5[0-9][0-9] (internal server error|bad gateway|service unavailable|gateway time-?out)'
transient+='|tls handshake timeout|connection reset by peer|i/o timeout|unexpected eof'
transient+='|temporary failure in name resolution|client\.timeout exceeded|net/http: request canceled'

errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

attempt=1
while :; do
  # stdout goes to the original stdout (fd 3), stderr through tee into the file.
  { "$@" 2>&1 1>&3 3>&- | tee "$errfile" >&2; rc="${PIPESTATUS[0]}"; } 3>&1
  [ "$rc" -ne 0 ] || exit 0
  if ! grep -Eiq "$transient" "$errfile"; then
    exit "$rc"
  fi
  if [ "$attempt" -ge "$max" ]; then
    echo "retry.sh: giving up after $attempt attempts (exit $rc): $*" >&2
    exit "$rc"
  fi
  idx=$((attempt - 1))
  [ "$idx" -lt "${#delays[@]}" ] || idx=$((${#delays[@]} - 1))
  base="${delays[$idx]}"
  wait=$((base + RANDOM % (base / 2 + 1)))
  echo "retry.sh: attempt $attempt/$max failed (exit $rc) with a transient registry error, retrying in ${wait}s: $*" >&2
  sleep "$wait"
  attempt=$((attempt + 1))
done
