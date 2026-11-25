#!/bin/sh
# Render the opcache.ini an image of a given PHP version ships.
#
#   shipped-opcache-ini.sh <php-version> <conf/opcache.ini> <destination>
#
# The one place the per-version adjustment lives. The Dockerfile's runtime-conf
# stage writes the image's 15-opcache.ini with it and php/pgo/train.sh writes the
# ini it trains under with it, so the profile is taken with exactly the settings
# the image runs and there is no second copy to drift.
#
# PHP before 7.3 cannot allocate the 32MB interned strings buffer that
# conf/opcache.ini asks for: there it is carved from opcache's shared segment with
# a 16MB ceiling, and exceeding it is a fatal "Zend OPcache cannot allocate buffer
# for interned strings" at startup. 7.0-7.2 images exited 254 before accepting a
# connection. 16 is still twice opcache's default of 8.
#
# PHP 8.0 and 8.1 ship with the JIT disabled: their tracing JIT segfaults workers
# in generated code under real applications, and both are end of life, so no
# upstream fix is coming. The entrypoint's generated ini defaults to the same.
#
# Guarded on both sides: `sed` exits 0 whether or not it matched, so a reworded
# conf/opcache.ini would silently turn the clamp into a no-op.
set -eu

version="${1:?usage: shipped-opcache-ini.sh <php-version> <conf/opcache.ini> <destination>}"
source_ini="${2:?usage: shipped-opcache-ini.sh <php-version> <conf/opcache.ini> <destination>}"
destination="${3:?usage: shipped-opcache-ini.sh <php-version> <conf/opcache.ini> <destination>}"

[ -f "$source_ini" ] || { echo "FATAL: no $source_ini" >&2; exit 1; }

case "$version" in
  7.0|7.1|7.2)
    grep -qx 'opcache.interned_strings_buffer = 32' "$source_ini" \
      || { echo "FATAL: $source_ini no longer sets interned_strings_buffer = 32; the <7.3 clamp is dead" >&2; exit 1; }
    sed 's/^opcache.interned_strings_buffer = 32$/opcache.interned_strings_buffer = 16/' "$source_ini" > "$destination"
    grep -qx 'opcache.interned_strings_buffer = 16' "$destination" \
      || { echo "FATAL: interned strings clamp did not apply" >&2; exit 1; }
    echo "ok: clamped interned_strings_buffer to 16 for php $version" >&2
    ;;
  8.0|8.1)
    grep -qx 'opcache.jit = tracing' "$source_ini" \
      || { echo "FATAL: $source_ini no longer sets opcache.jit = tracing; the 8.0/8.1 JIT override is dead" >&2; exit 1; }
    sed 's/^opcache.jit = tracing$/opcache.jit = disable/' "$source_ini" > "$destination"
    grep -qx 'opcache.jit = disable' "$destination" \
      || { echo "FATAL: 8.0/8.1 JIT override did not apply" >&2; exit 1; }
    echo "ok: disabled the JIT for php $version" >&2
    ;;
  *)
    cp "$source_ini" "$destination"
    ;;
esac
