#!/usr/bin/env bash
# Build the vendored dependency set for a legacy PHP version.
# OpenSSL and ICU are built static-only: an EOL libssl.so (or a duplicate ICU
# data blob) in the image is a liability for everything else that might dlopen
# it. curl (7.0-7.2 only, per versions.lock) stays shared, resolved via rpath at
# the same prefix, like ImageMagick. libxml2 is not vendored: trixie's package
# is the 2.9.14 series with security backports that upstream's tarball lacks,
# so deps-legacy installs libxml2-dev from apt instead.
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
# that library on that PHP, or nothing if it vendors none, and exits without
# fetching or building. tests/smoke.sh uses it to learn which ICU an image
# should report, sharing the range arithmetic with the builder.
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
# ICU is C++ and needs CXXFLAGS for PIC objects: the gcc image's compiler does
# not default to PIE, and the PIE php link would fail on libicu*.a relocations.
# -std=gnu17 is C-only, so it is dropped; ICU picks its own C++ standard.
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
      # no-legacy is a 3.x-only ./config option; 1.1.1w rejects it as
      # "Unsupported options".
      #
      # --openssldir is not a build output location: it is the compiled-in
      # runtime default for the CA trust store, and "make install_sw" (libs and
      # headers only) never populates it. Pointing it at the vendored prefix
      # would leave default_cert_file/default_cert_dir dangling and break peer
      # verification for every TLS stream PHP's openssl extension opens
      # (file_get_contents, SoapClient, SMTP+TLS; curl resolves its CA bundle
      # independently). /etc/ssl is Debian's maintained store. conf/openssl.ini
      # also sets openssl.cafile explicitly, as an independent second line of
      # defense.
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

# Static archives (openssl, icu) and libtool .la files stay: the php-build
# stage, built FROM this one, links against them. Stripping them is the runtime
# image's job once PHP is linked; see stage_runtime_deps() in php/build.sh.
echo "vendored deps installed to $PREFIX"
