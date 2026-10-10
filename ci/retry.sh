#!/usr/bin/env bash
# Retry safe-to-repeat commands when stderr matches a selected transient kind.
# Usage: ci/retry.sh <command> [args...]
# RETRY_KIND: comma-separated registry (default), net, http, composer (http alias),
# apt, git. Every kind includes net; permanent errors take precedence.
# RETRY_DELAYS: seconds before each retry, plus up to 50% jitter. Defaults are
# "30 60 120 300 600 900" with registry, otherwise "5 15 45 120".
# RETRY_ATTEMPTS: total attempts, default one more than the number of delays.
# The last delay repeats for extra attempts. Output and command exit codes pass
# through; only stderr is matched, case-insensitively. Callers decide retry safety.
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
