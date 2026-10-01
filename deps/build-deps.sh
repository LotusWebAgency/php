#!/usr/bin/env bash
# Build the vendored dependency set for a legacy PHP version.
# OpenSSL and ICU are built no-shared/static-only on purpose: an EOL libssl.so
# (or a duplicate ICU data blob) in the image is a liability for everything
# else that might dlopen it. curl (7.0-7.2 only, per versions.lock) stays
# shared, resolved via rpath at the same prefix -- same pattern as
# ImageMagick. libxml2 is not vendored at all (task 14 review, I2): trixie's
# own package is the 2.9.14 series with security backports upstream's bare
# tarball lacks, so deps-legacy installs libxml2-dev from apt instead.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

in_range() {  # in_range <applies-to> <version>  e.g. "7.0-7.3" "7.2"
  local range="$1" v="$2"
  [ "$range" = "all" ] && return 0
  local lo="${range%%-*}" hi="${range##*-}"
  local vk=$(( ${v%%.*} * 100 + ${v##*.} ))
  local lk=$(( ${lo%%.*} * 100 + ${lo##*.} ))
  local hk=$(( ${hi%%.*} * 100 + ${hi##*.} ))
  [ "$vk" -ge "$lk" ] && [ "$vk" -le "$hk" ]
}

# --pin <name> <php-version> prints the version this build would vendor for
# that library on that PHP, or nothing if it vendors none, and exits. Nothing
# is fetched or built. tests/smoke.sh uses it to know which ICU an image
# is supposed to report -- deriving that from the same rows and the same range
# arithmetic the builder uses, rather than reimplementing "7.0-7.3" parsing in
# a second place where it can disagree.
if [ "${1:-}" = "--pin" ]; then
  want="${2:?usage: build-deps.sh --pin <name> <php-version>}"
  for_version="${3:?usage: build-deps.sh --pin <name> <php-version>}"
  while read -r era name version applies _sha _url; do
    case "$era" in ''|\#*) continue ;; esac
    [ "$name" = "$want" ] || continue
    in_range "$applies" "$for_version" || continue
    echo "$version"
  done < "${HERE}/versions.lock"
  exit 0
fi

PHP_VERSION="${1:?usage: build-deps.sh <php-version> [prefix]}"
PREFIX="${2:-/opt/php-deps}"

export CFLAGS="$(bash "${HERE}/../php/cflags.sh" "${UARCH:-baseline}")"
# ICU is C++, and without CXXFLAGS its objects were built non-PIC. Debian's
# gcc defaults to PIE and hid that; GCC 16.2 from the gcc image does not, and
# the PIE php link then fails on libicu*.a relocations. -std=gnu17 is C-only,
# so it is dropped here -- ICU picks its own C++ standard.
export CXXFLAGS="$(printf '%s' "$CFLAGS" | sed -E 's/(^| )-std=[^ ]+//g')"
export LDFLAGS="$(bash "${HERE}/../php/ldflags.sh" "$PREFIX")"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
mkdir -p "$PREFIX"

fetch() {  # fetch <url> <sha256> <dest>
  bash "${HERE}/fetch-verified.sh" "$1" "$2" "$3"
}

while read -r era name version applies sha url; do
  case "$era" in ''|\#*) continue ;; esac
  [ "$era" = "legacy" ] || continue
  in_range "$applies" "$PHP_VERSION" || continue

  echo "=== building $name $version for php $PHP_VERSION"
  work="/tmp/build-${name}"
  rm -rf "$work" && mkdir -p "$work"
  fetch "$url" "$sha" "/tmp/${name}.tar"
  tar xf "/tmp/${name}.tar" -C "$work" --strip-components=1
  rm -f "/tmp/${name}.tar"

  case "$name" in
    openssl)
      # no-legacy is a 3.x-only ./config option (the legacy provider is a 3.0
      # concept); passing it to 1.1.1w's ./config is a hard "Unsupported
      # options" failure, not a no-op.
      #
      # --openssldir is NOT a build output location -- it's baked into the
      # binary as the compiled-in default for where OpenSSL looks for a CA
      # trust store (cert.pem / certs/) at *runtime*, and "make install_sw"
      # (installs libs/headers only, deliberately not "make install") never
      # populates it regardless of where it points. Pointing it at the
      # vendored prefix left /opt/php-deps/ssl not existing at all --
      # openssl_get_cert_locations() reported default_cert_file=/opt/php-deps/
      # ssl/cert.pem and default_cert_dir=/opt/php-deps/ssl/certs, neither
      # real, and every TLS connection made through PHP's own openssl
      # extension (file_get_contents, stream_socket_client, SoapClient,
      # SMTP+TLS -- anything not going through curl, which resolves its CA
      # bundle independently of PHP's openssl config) failed to verify the
      # peer and errored out. curl_exec() masked this completely since it
      # never consults these paths. Pointing --openssldir at /etc/ssl instead
      # means the compiled-in default is Debian's own ca-certificates-
      # maintained store (/etc/ssl/certs, already real and already updated by
      # unattended apt upgrades) rather than an empty private one -- this is
      # also why openssl.cafile is set explicitly in conf/openssl.ini rather
      # than relying on this alone: the two are independent lines of defense,
      # not redundant (the ini path is read by PHP for every stream-openssl
      # call regardless of what OpenSSL's own compiled-in default is, and
      # would keep working even if this default were ever wrong or the
      # detection above changes upstream).
      ( cd "$work" && ./config --prefix="$PREFIX" --openssldir=/etc/ssl \
          no-shared no-tests \
        && make -j"$(nproc)" && make install_sw )
      ;;
    icu)
      ( cd "$work/source" && ./configure --prefix="$PREFIX" \
          --disable-samples --disable-tests --enable-static --disable-shared \
        && make -j"$(nproc)" && make install )
      ;;
    curl)
      ( cd "$work" && ./configure --prefix="$PREFIX" --with-openssl="$PREFIX" \
          --disable-ldap --disable-ldaps --without-libpsl --enable-versioned-symbols \
        && make -j"$(nproc)" && make install )
      ;;
    *)
      echo "no build recipe for $name" >&2; exit 1 ;;
  esac
  rm -rf "$work"
done < "${HERE}/versions.lock"

# Static archives (openssl, icu) and libtool .la files stay right here: the
# php-build stage (a later, separate stage FROM this one) still has to link
# against them. Stripping them is the runtime image's job, once PHP itself
# has finished linking -- see stage_runtime_deps() in php/build.sh, which is
# what actually reaches the shipped image (deps-stage, not this prefix).
echo "vendored deps installed to $PREFIX"
