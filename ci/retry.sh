#!/usr/bin/env bash
# Run a command, retrying it with backoff when it fails the way a busy registry
# or network fails, and only then.
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
#   RETRY_KIND      what counts as transient, comma-separated (default "registry"):
#                   registry  429, 5xx and GHCR's `unknown blob` from docker, buildx, cosign
#                   http      curl/composer transfer errors, HTTP 408/429/5xx (`composer` is an alias)
#                   apt       `Failed to fetch` with a 5xx, hash sum mismatches
#                   git       RPC failures, HTTP 429/5xx, TLS handshake failures
#                   net       DNS, refused/reset/timed-out connections, truncated transfers;
#                             every kind includes it
#                   Certificate errors, sha256 mismatches, unresolvable composer
#                   requirements, missing apt packages or repositories and failed
#                   authentication are never retried, whatever else matched.
#   RETRY_DELAYS    seconds to wait before retry 1, 2, ... (default "30 60 120 300 600 900"
#                   when RETRY_KIND includes registry, else "5 15 45 120");
#                   the last one repeats if RETRY_ATTEMPTS asks for more attempts
#   RETRY_ATTEMPTS  attempts in total (default: one more than RETRY_DELAYS has entries)
#
# Only the command's stderr is matched (that is where docker, buildx, cosign,
# curl, composer, git and apt print their errors). Its stdout is passed straight
# through and never buffered, so a long `docker buildx bake` still streams -- which also means a
# failed attempt's stdout is not discarded: wrap commands that print their result
# on success only (`imagetools inspect --raw`, `docker pull`), not ones that
# print and then fail.
#
# Retried commands must be safe to run again; the callers decide that
# (see the comments at each call site).
#
# Needs only bash, grep, tee, mktemp and sleep, so it can be bind-mounted into
# test containers.
set -uo pipefail
[ "$#" -ge 1 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }

selection="${RETRY_KIND-registry}"
case "$selection" in
  ''|,*|*,|*,,*|*$'\n'*) echo "retry.sh: invalid RETRY_KIND: $selection" >&2; exit 2 ;;
esac
IFS=',' read -ra kinds <<<"$selection"
registry_selected=0
for kind in "${kinds[@]}"; do
  case "$kind" in
    registry) registry_selected=1 ;;
    net|http|composer|apt|git) ;;
    *) echo "retry.sh: unknown RETRY_KIND: $kind" >&2; exit 2 ;;
  esac
done
if [ "$registry_selected" -eq 1 ]; then
  default_delays="30 60 120 300 600 900"
else
  default_delays="5 15 45 120"
fi
read -ra delays <<<"${RETRY_DELAYS:-$default_delays}"
[ "${#delays[@]}" -gt 0 ] || delays=(0)
max="${RETRY_ATTEMPTS:-$((${#delays[@]} + 1))}"

registry='too many requests|toomanyrequests'
registry+='|(unexpected status|status code|http status)[^[:cntrl:]]*[ :]5[0-9][0-9]( |$)'
registry+='|\]\[5[0-9][0-9]\]'
registry+='|5[0-9][0-9] (internal server error|bad gateway|service unavailable|gateway time-?out)'
registry+='|tls handshake timeout|connection reset by peer|i/o timeout|unexpected eof'
registry+='|temporary failure in name resolution|client\.timeout exceeded|net/http: request canceled'
# GHCR may reject a just-accepted layer; pushing again completes it.
registry+='|(^|: )unknown blob$'

net='temporary failure in name resolution|temporary failure resolving|could not resolve (host|proxy)'
net+='|lookup [^ ]+( on [^ ]+)?: (no such host|server misbehaving|i/o timeout)|getaddrinfo .* failed'
net+='|connection (reset by peer|refused|timed out)|operation timed out|network is unreachable'
net+="|(failed|unable|could not) to connect to|couldn't connect to server"
net+='|tls handshake timeout|ssl_error_syscall|unexpected eof|early eof|empty reply from server'
net+='|recv failure|send failure|transfer closed with [0-9]+ bytes remaining'
net+='|http/2 stream [0-9]+ was not closed cleanly|i/o timeout|client\.timeout exceeded|net/http: request canceled'
http='curl: \((6|7|18|28|35|52|55|56|92)\)|curl error (6|7|18|28|35|52|55|56|92) while downloading'
http+='|returned error: (408|429|5[0-9][0-9])|\(HTTP/[0-9.]+ (408|429|5[0-9][0-9])'
http+='|the requested url returned error: (408|429|5[0-9][0-9])'
apt='failed to fetch .*(5[0-9][0-9]|hash sum mismatch)|hash sum mismatch'
git='rpc failed; (curl [0-9]+|http (429|5[0-9][0-9]))'
git+='|the requested url returned error: (429|5[0-9][0-9])|gnutls_handshake\(\) failed'
deny='ssl certificate problem|certificate verify failed|sha256 mismatch|your requirements could not be resolved'
deny+='|api rate limit exceeded|unable to locate package|repository not found|authentication failed'

errfile="$(mktemp)"
trap 'rm -f "$errfile"' EXIT

attempt=1
while :; do
  # stdout goes to the original stdout (fd 3), stderr through tee into the file.
  { "$@" 2>&1 1>&3 3>&- | tee "$errfile" >&2; rc="${PIPESTATUS[0]}"; } 3>&1
  [ "$rc" -ne 0 ] || exit 0
  if grep -Eiq "$deny" "$errfile"; then
    exit "$rc"
  fi
  matched_kind=''
  for kind in "${kinds[@]}"; do
    [ "$kind" != composer ] || kind=http
    case "$kind" in
      registry) transient="$registry" ;;
      http) transient="$http" ;;
      apt) transient="$apt" ;;
      git) transient="$git" ;;
      net) continue ;;
    esac
    if grep -Eiq "$transient" "$errfile"; then
      matched_kind="$kind"
      break
    fi
  done
  if [ -z "$matched_kind" ] && grep -Eiq "$net" "$errfile"; then
    matched_kind=net
  fi
  [ -n "$matched_kind" ] || exit "$rc"
  if [ "$attempt" -ge "$max" ]; then
    echo "retry.sh: giving up after $attempt attempts (exit $rc): $*" >&2
    exit "$rc"
  fi
  idx=$((attempt - 1))
  [ "$idx" -lt "${#delays[@]}" ] || idx=$((${#delays[@]} - 1))
  base="${delays[$idx]}"
  wait=$((base + RANDOM % (base / 2 + 1)))
  echo "retry.sh: attempt $attempt/$max failed (exit $rc) with a transient $matched_kind error, retrying in ${wait}s: $*" >&2
  sleep "$wait"
  attempt=$((attempt + 1))
done
