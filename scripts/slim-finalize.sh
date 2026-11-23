#!/usr/bin/env bash
# Final trim of a slim image (fpm-slim, cli-slim): refuse an image that still has
# apk, strip setuid bits, prune the busybox applet links to an allowlist and check
# that the other executables in the binary directories are exactly the names in
# scripts/slim-native-keep.txt (the runtime-rootfs-slim stage deleted the rest).
# Every command goes through `busybox <applet>`, so the script does not depend on
# the links it removes.
set -euo pipefail

bb=/usr/bin/busybox
native_keep_file=/tmp/slim-native-keep.txt

# Entrypoint and helper scripts: env sh tr sed awk grep cut wc uniq tail cat id
# stat flock rm mkdir mktemp chmod mv ln touch (docker-php-entrypoint), true
# (the command its flock probe runs), false (its pair), ls
# (php-ext-enable), head od timeout gzip (sp-upload-check), sleep date nologin
# (tests, user parity). sh stays: the HEALTHCHECK is shell form and Symfony
# Process uses /bin/sh.
allowlist="env sh tr sed awk grep cut wc uniq tail cat id stat flock rm mkdir mktemp chmod mv ln touch true false ls head od timeout gzip sleep date nologin"

[ -x "$bb" ] || { echo "error: $bb is missing" >&2; exit 1; }
[ -s "$native_keep_file" ] || { echo "error: $native_keep_file is missing" >&2; exit 1; }

for path in /sbin/apk /usr/sbin/apk /bin/apk /usr/bin/apk; do
  if [ -e "$path" ]; then
    echo "error: $path exists; build this target with RUNTIME_OS=slim" >&2
    exit 1
  fi
done

[ -s /lib/apk/db/installed ] || { echo "error: /lib/apk/db/installed is missing" >&2; exit 1; }
[ -s /etc/os-release ] || { echo "error: /etc/os-release is missing" >&2; exit 1; }

"$bb" find / -xdev -perm /6000 -type f -exec "$bb" chmod a-s {} +

bindirs="/usr/bin /usr/sbin /bin /sbin"
real_bb="$("$bb" readlink -f "$bb")"

# Names of the busybox links in the binary directories, except busybox itself.
# /bin, /sbin and /usr/sbin are symlinks into /usr/bin here, so the list is
# deduplicated.
busybox_links() {
  local dir entry
  for dir in $bindirs; do
    for entry in "$dir"/*; do
      [ -L "$entry" ] || continue
      [ "$("$bb" readlink -f "$entry")" = "$real_bb" ] || continue
      [ "${entry##*/}" = busybox ] || echo "${entry##*/}"
    done
  done | "$bb" sort -u
}

in_allowlist() {
  case " $allowlist " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

for name in $(busybox_links); do
  in_allowlist "$name" && continue
  for dir in $bindirs; do
    if [ -L "$dir/$name" ] && [ "$("$bb" readlink -f "$dir/$name")" = "$real_bb" ]; then
      "$bb" rm -f "$dir/$name"
    fi
  done
done

# The remaining links must be exactly the allowlist.
want="$("$bb" tr ' ' '\n' <<<"$allowlist" | "$bb" sort -u)"
have="$(busybox_links)"
if [ "$want" != "$have" ]; then
  echo "error: busybox links differ from the allowlist" >&2
  echo "allowlist: ${want//$'\n'/ }" >&2
  echo "present:   ${have//$'\n'/ }" >&2
  exit 1
fi
echo "ok: busybox links pruned to: $allowlist"

# Every other entry in the binary directories is a native tool; /bin, /sbin and
# /usr/sbin lead to /usr/bin, so one directory covers them.
want_native="$("$bb" sort -u "$native_keep_file")"
have_native="$(
  for entry in /usr/bin/* /usr/bin/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    [ "${entry##*/}" = busybox ] && continue
    [ "$("$bb" readlink -f "$entry")" = "$real_bb" ] && continue
    echo "${entry##*/}"
  done | "$bb" sort -u
)"
if [ "$want_native" != "$have_native" ]; then
  echo "error: native executables in /usr/bin differ from scripts/slim-native-keep.txt" >&2
  echo "keep list: ${want_native//$'\n'/ }" >&2
  echo "present:   ${have_native//$'\n'/ }" >&2
  exit 1
fi
echo "ok: native executables are exactly: ${want_native//$'\n'/ }"
