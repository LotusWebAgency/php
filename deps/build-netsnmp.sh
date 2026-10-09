#!/usr/bin/env bash
# Minimal net-snmp, built from the source pinned in deps/versions.lock: the
# client library (libnetsnmp) and the MIB files, nothing else.
#
# Why: Debian's libsnmp40t64 hard-depends on libperl5.40 (plus libwrap0,
# libsensors5, libpci3) for the agent's embedded-perl glue. ext-snmp only needs
# the client library, but the distro copy drags ~49 MB of perl into every
# runtime image, and purging perl is impossible while another package depends
# on it.
#
# Left out: the agent and its mib modules, the command-line apps, scripts
# (mib2c...), manuals, perl and python bindings, embedded perl, libwrap. Kept,
# to match Debian's libsnmp where PHP users can see it: OpenSSL for USM
# auth/priv (Debian's supported libssl, never an EOL one, and never the
# static-only vendored 1.1.1w), AES-192/256 priv (--enable-blumenthal-aes), the
# TLS/DTLS transports, the TSM security model, IPv6.
#
# Defaults follow Debian so existing deployments keep working:
#   - /etc/snmp is the config directory, so a mounted /etc/snmp/snmp.conf is
#     read as on a Debian host, and /var/lib/snmp is the persistent dir.
#   - No MIB is loaded automatically (--with-mibs=":" matches the `mibs :` in
#     Debian's snmp.conf). Auto-loading would turn snmp2_walk() keys from
#     numeric OIDs into SNMPv2-MIB::sysDescr.0 names and make every PHP start
#     parse about twenty MIB files. The files are installed and listed in the
#     compiled-in MIB directories, so snmp_read_mib(), MIBS=ALL and `mibs +ALL`
#     work.
#   - The MIB search path is Debian's (`net-snmp-config --default-mibdirs` on a
#     trixie libsnmp-dev: $HOME/.snmp/mibs and /usr/share/snmp/mibs with its
#     iana and ietf subdirectories, which are not searched recursively) plus
#     the shipped MIB directory, so MIBs mounted where a Debian host expects
#     them are found without setting MIBDIRS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PREFIX="${1:-/opt/net-snmp}"

row=$(grep -E '^both[[:space:]]+net-snmp[[:space:]]' "$HERE/versions.lock")
version=$(echo "$row" | awk '{print $3}')
sha=$(echo "$row" | awk '{print $5}')
url=$(echo "$row" | awk '{print $6}')

bash "$HERE/fetch-verified.sh" "$url" "$sha" /tmp/net-snmp.tar.gz
mkdir -p /tmp/net-snmp && tar xf /tmp/net-snmp.tar.gz -C /tmp/net-snmp --strip-components=1
cd /tmp/net-snmp

# Same posture as ImageMagick: one build shared by all PHP versions, baseline
# flags, hardening from the shared flag scripts, self-referencing rpath.
export CFLAGS
CFLAGS="$(bash "$ROOT/php/cflags.sh" baseline)"
export LDFLAGS
LDFLAGS="$(bash "$ROOT/php/ldflags.sh" "$PREFIX")"

# --with-defaults: configure otherwise prompts on stdin for the contact,
# location and default version.
./configure \
  --prefix="$PREFIX" \
  --sysconfdir=/etc \
  --with-persistent-directory=/var/lib/snmp \
  --with-defaults \
  --enable-shared --disable-static \
  --enable-as-needed \
  --disable-agent --disable-applications --disable-manuals --disable-scripts \
  --disable-embedded-perl --without-perl-modules --without-python-modules \
  --without-libwrap --without-rpm --without-nl \
  --with-logfile=none \
  --with-openssl \
  --enable-blumenthal-aes \
  --with-transports="TLSTCP DTLSUDP" \
  --with-security-modules=tsm \
  --with-mibs=":" \
  --with-mibdirs="\$HOME/.snmp/mibs:$PREFIX/share/snmp/mibs:/usr/share/snmp/mibs:/usr/share/snmp/mibs/iana:/usr/share/snmp/mibs/ietf"

make -j"$(nproc)"
make install

find "$PREFIX/lib" -name '*.la' -delete
find "$PREFIX/lib" -name '*.a' -delete
find "$PREFIX/lib" -type f -name '*.so*' -exec strip --strip-unneeded {} +

cd / && rm -rf /tmp/net-snmp /tmp/net-snmp.tar.gz
echo "net-snmp $version installed to $PREFIX"
