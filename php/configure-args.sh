#!/usr/bin/env bash
# Print ./configure flags for a PHP version, derived from php/ext.json.
#
# The optional source filter restricts which extensions contribute flags:
# `core` for what php-src ships, `pecl` for what has to be unpacked into ext/
# first, `all` (the default) for both. The fixed preamble below is always
# printed. Task 6 builds core-only because the pecl sources do not exist in the
# tree yet and an unknown flag is fatal under --enable-option-checking=fatal.
set -euo pipefail
VERSION="${1:?usage: configure-args.sh <php-version> [core|pecl|all]}"
SOURCES="${2:-all}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$SOURCES" in
  core|pecl|all) ;;
  *) echo "unknown source filter: $SOURCES (want core, pecl or all)" >&2; exit 1 ;;
esac

# Flags that are not extension-driven and apply to every build.
cat <<EOF
--prefix=/usr/local
--enable-option-checking=fatal
--enable-cli
--enable-fpm
--with-fpm-user=www-data
--with-fpm-group=www-data
--disable-cgi
--disable-phpdbg
--with-config-file-path=/usr/local/etc/php
--with-config-file-scan-dir=/usr/local/etc/php/conf.d
--enable-mysqlnd
--with-pic
EOF

# Argon2 password hashing landed in PHP 7.2 (ext/standard's password API,
# --with-password-argon2 + libargon2). 7.0 and 7.1 register no option by that
# name at all, and the preamble above asks for --enable-option-checking=fatal,
# which turns an unrecognized flag into a hard `configure: error` rather than
# the warning it would otherwise be -- so this cannot simply be passed
# everywhere and left to be ignored on the branches that predate it.
# Confirmed by grepping the option table of each release's own generated
# configure --help: absent in 7.0.33/7.1.33, present from 7.2.34 on.
if [ "$(( ${VERSION%%.*} * 100 + ${VERSION#*.} ))" -ge 702 ]; then
  echo "--with-password-argon2"
fi

python3 - "$VERSION" "$HERE/ext.json" "$SOURCES" <<'PY'
import json, sys

version, path, sources = sys.argv[1], sys.argv[2], sys.argv[3]


def parts(v):
    return tuple(int(x) for x in v.split("."))


def satisfies(constraint, v):
    if not constraint:
        return True
    for clause in constraint.split(","):
        clause = clause.strip()
        for op in (">=", "<=", "<", ">", "=="):
            if clause.startswith(op):
                bound = parts(clause[len(op):])
                cur = parts(v)
                ok = {
                    ">=": cur >= bound, "<=": cur <= bound,
                    "<": cur < bound, ">": cur > bound, "==": cur == bound,
                }[op]
                if not ok:
                    return False
                break
    return True


registry = json.load(open(path))["extensions"]
for ext in registry:
    override = (ext.get("overrides") or {}).get(version, {})
    linkage = override.get("linkage", ext["linkage"])
    if linkage != "static":
        continue
    if sources != "all" and ext["source"] != sources:
        continue
    if not satisfies(ext["php"], version):
        continue
    configure = override.get("configure", ext["configure"])
    if configure:
        for flag in configure.split():
            print(flag)
PY
