# php: PHP 7.0-8.5, compiled from source, PGO-trained on real apps

PHP 7.0 through 8.5, compiled from source on Wolfi (`cgr.dev/chainguard/wolfi-base`, pinned by
digest) with profile-guided optimization (PGO) trained on real PrestaShop, WordPress, Laravel,
Symfony and Drupal applications. Binaries are hardened at the ELF level, Snuffleupagus virtual
patching is available, and a read-only root filesystem is supported. A complete hardened setup is in
[Hardened deployment](https://github.com/LotusWebAgency/php#hardened-deployment); the [Image contract](https://github.com/LotusWebAgency/php#image-contract) lists the
facts a deployment script or agent needs.

Source and full docs: [github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Replaces `dementev/php-fpm-with-ext`
([migration notes](https://github.com/LotusWebAgency/php#migrating-from-php-fpm-with-ext)).
Coming from a Debian- or Alpine-based PHP image? See
[Moving from a Debian or Alpine base](https://github.com/LotusWebAgency/php#moving-from-a-debian-or-alpine-base).

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    volumes:
      - ./:/app
```

## Tags

All 11 PHP versions ship all four flavors for `linux/amd64` and `linux/arm64`. Support status and EOL
dates are upstream's ([php.net](https://www.php.net/supported-versions.php)) and are also image labels.

| PHP | Compiler | `-v3` | Support | EOL date |
|---|---|---|---|---|
| `7.0` | gcc | no | end-of-life | 2019-01-10 |
| `7.1` | gcc | no | end-of-life | 2019-12-01 |
| `7.2` | gcc | no | end-of-life | 2020-11-30 |
| `7.3` | gcc | no | end-of-life | 2021-12-06 |
| `7.4` | gcc | no | end-of-life | 2022-11-28 |
| `8.0` | gcc | no | end-of-life | 2023-11-26 |
| `8.1` | gcc | no | end-of-life | 2025-12-31 |
| `8.2` | gcc | no | security | 2026-12-31 |
| `8.3` | gcc | no | security | 2027-12-31 |
| `8.4` | gcc | yes | active | 2028-12-31 |
| `8.5` | clang | yes | active | 2029-12-31 |

End-of-life tags are still published and rebuilt weekly for base-image and package updates. The PHP
interpreter in them gets no upstream fixes. Policy:
[SUPPORT.md](https://github.com/LotusWebAgency/php/blob/main/SUPPORT.md).

### Older PHP versions

- 8.1 and below get no upstream security fixes. 7.0-8.0 link a vendored OpenSSL 1.1.1w, ICU,
  libxml2 and libxslt statically.
- mysqli/PDO support `caching_sha2_password` from 7.4. 7.1-7.3 need `mysql_native_password`
  accounts on MySQL 8 and cannot reach MySQL 9. 7.0 also needs the server's default plugin set to
  `mysql_native_password`. 7.0 and 7.1 speak TLS 1.0 only, which MySQL 8.4 and MariaDB 11 refuse.
- No JIT below 8.0 (8.0: amd64 only). `-v3` tags are 8.4 and 8.5 only.

Every caveat, with workarounds:
[Older PHP versions](https://github.com/LotusWebAgency/php/blob/main/README.md#older-php-versions).

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every published image. |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | Built for `x86-64-v3` / `armv9-a` instead of the `x86-64-v2` / `armv8-a` baseline. 8.4 and 8.5 only. |
| `{version}`, `latest` | `8.5`, `latest` | The default version's `fpm` image. |
| `{release}-{flavor}[-v3]` | `8.5.12-fpm` | Full patch version, read from the built image after tests and the Trivy gate. |

`-v3` needs a newer CPU. On older amd64 the image refuses to start (a startup
check prints `this build requires an x86-64-v3 CPU`, exit 127). On arm64 there is no check and an unsupported core
gets SIGILL: `armv9-a` code needs Neoverse N2/V2-class cores (Graviton4, Axion, Cobalt 100, Grace),
not Graviton2/3, Ampere Altra or Apple silicon. Use the baseline tag on a Mac.

The amd64 baseline is `x86-64-v2` (SSE4.2 and POPCNT; Intel Nehalem and newer, AMD Bulldozer and
newer), not plain `x86-64`, because Wolfi's packages are built for it. Both baselines use generic
tuning. amd64 `-v3` also tunes generic; arm64 `-v3` tunes for `neoverse-v2`. Only the amd64 `-v3`
tags check the CPU at startup. The vendored ImageMagick, heif stack (libheif, libde265, dav1d) are
built for the baseline in every image, `-v3` included.

`8.4-fpm` moves with each 8.4 patch release. Pin the digest for reproducible builds.

## Flavors

| Flavor | Contents |
|---|---|
| `fpm` | PHP-FPM on `:9000` for a FastCGI-speaking reverse proxy. `STOPSIGNAL SIGQUIT` and a FastCGI `HEALTHCHECK` that needs no web server. |
| `cli` | `php -a` by default. Scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, Node.js 26 with npm 12.2.1 and corepack, semantic-release and Composer. No compiler. For build stages. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, glibc and Linux headers and the PHP headers with `phpize`. Runs as root. Extensions take Wolfi's default `-march`/`-mtune`; `-v3` presets `CFLAGS`/`CXXFLAGS`. For build stages. |

All images run `tini` as PID 1. All but `ext-builder` run as `www-data` (UID and GID 33).

### Base image and tools

The base is Wolfi, a glibc distribution, with `packages.wolfi.dev/os` as the only apk repository.
Every flavor has `apk`, bash, curl, nano, less, procps, tzdata, ca-certificates, zip, unzip, zstd, xz,
bzip2, the PostgreSQL 18 client (`psql`, `pg_dump`, `pg_restore`) and the MariaDB 13.1 client.
`mysql`, `mysqldump`, `mysqladmin` and `mysqlcheck` are wrapper scripts that `exec` `mariadb`,
`mariadb-dump`, `mariadb-admin` and `mariadb-check`. They log in with every MySQL, Percona and
MariaDB password plugin, including `caching_sha2_password`, and use TLS when the server offers it
(`/etc/my.cnf`; `--ssl-verify-server-cert` to verify). The fpm healthcheck uses `php-fcgi`, a small
FastCGI client shipped in every flavor, since Wolfi has no `cgi-fcgi`.

There is no apt, dpkg, `ldd`, `getent`, `useradd` or other shadow tool. `fpm` and `cli` have no perl;
`cli-builder` and `ext-builder` do, because git and autoconf need it.

## Quick start

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    volumes:
      - ./:/app
    environment:
      PHP_TIMEZONE: Europe/Bangkok
      PHP_MEMORY_LIMIT: 512M
```

Point your FastCGI proxy at `php:9000`. Multi-stage build:

```dockerfile
FROM lotuswebagency/php:8.5-cli-builder AS build
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --optimize-autoloader
COPY . .

FROM lotuswebagency/php:8.5-fpm
COPY --from=build /app /app
```

## Image contract

The facts a deployment script, CI job or coding agent needs, in one place. Everything here holds for
every tag unless the row says otherwise.

| Item | Value |
|---|---|
| Entrypoint | `/usr/bin/tini -- docker-php-entrypoint`. tini is already PID 1: do not add `--init` / `init: true`, or tini warns that it is not PID 1. |
| Default command | `fpm`: `php-fpm -F`. `cli`: `php -a`. `cli-builder`, `ext-builder`: `bash`. |
| User | `www-data`, UID and GID 33. `ext-builder` runs as root. |
| Working directory | `/app`, owned by `www-data`. |
| Port | `fpm`: 9000/tcp, FastCGI only (no HTTP). Status `/fpm-status`, ping `/fpm-ping`. |
| Healthcheck | `fpm` only, baked: `php-fpm-healthcheck` (FastCGI, no web server needed). |
| Stop signal | `fpm`: `SIGQUIT` (graceful). |
| Logs | stderr only; no log files. |
| Writable paths at runtime | `/tmp` only, plus whatever the application itself writes. |
| Configuration | `PHP_*` environment variables, applied at start. Drop-in ini files go in `/usr/local/etc/php/conf.d/` and must sort after `10-php.ini`. |
| Extensions | 53 compiled in; 19 shared, loaded with `PHP_EXT_ENABLE`. List: `php -m`. |
| Snuffleupagus | Off by default. `PHP_SNUFFLEUPAGUS=<ruleset>`; rulesets in `/usr/local/etc/php/snuffleupagus/`. PHP 7.2+. |
| `docker exec` | `docker exec <c> docker-php-entrypoint php ...` sees the env-driven ini; plain `docker exec <c> php ...` does not. |
| Package manager | `apk` (Wolfi). No apt, `pecl` or `docker-php-ext-install`. |
| Pinning | Tags move with patch releases and weekly rebuilds. Pin `@sha256:...` for reproducible deploys. |

## Configuration

The entrypoint turns environment variables into ini files and FPM pool settings once at start. A
variable that is set but empty, or contains a newline, stops the container with a message naming it.

| Variable | Default | Sets |
|---|---|---|
| `PHP_MEMORY_LIMIT` | fpm `256M`, cli and ext-builder `512M`, cli-builder `-1` | `memory_limit` |
| `PHP_MAX_EXECUTION_TIME` | fpm `300`, others `0` | `max_execution_time` |
| `PHP_MAX_INPUT_TIME`, `PHP_MAX_INPUT_VARS` | `120`, `10000` | `max_input_time`, `max_input_vars` |
| `PHP_UPLOAD_MAX_FILESIZE`, `PHP_POST_MAX_SIZE` | `128M`, `128M` | `upload_max_filesize`, `post_max_size` |
| `PHP_TIMEZONE` | unset | `date.timezone` |
| `PHP_ERROR_REPORTING` | `E_ALL & ~E_DEPRECATED` | `error_reporting` |
| `PHP_DISPLAY_ERRORS` | `Off` | `display_errors`. Errors go to stderr regardless. |
| `PHP_DISABLE_FUNCTIONS` | fpm: `passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec`. cli, ext-builder: unset; the same list is baked into `10-php.ini`. cli-builder: none | Adds to the baked and mounted-ini lists, never replaces them. `proc_open` stays enabled for Composer. |
| `PHP_OPCACHE_ENABLE` | `1` | `opcache.enable` |
| `PHP_OPCACHE_MEMORY` | one eighth of the container memory limit, 64-512 MB | `opcache.memory_consumption` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS`, `PHP_OPCACHE_REVALIDATE_FREQ` | `1`, `2` | Set validation to `0` when deploys replace the whole tree. |
| `PHP_OPCACHE_PRELOAD` | unset | `opcache.preload` |
| `PHP_OPCACHE_JIT`, `PHP_OPCACHE_JIT_BUFFER` | `tracing`, `64M` | PHP 8.1+, and 8.0 on amd64 (8.0 on arm64 has no JIT). |
| `PHP_EXT_ENABLE` | unset | Comma-separated shared extensions to load, for example `ldap,uuid`. |
| `PHP_SNUFFLEUPAGUS` | unset | `default`, `wordpress`, `prestashop`, `laravel`, or a custom ruleset name. |
| `PHP_CHMOD_SHIM` | `0` | `true` enables the PrestaShop `chmod(0)` cache-bug shim. |
| `PHP_INI_SCAN_DIR` | image default | Standard PHP variable. The baked `conf.d` is added back in. |

`fpm` only: `PHP_FPM_PM` (`dynamic`), `PHP_FPM_MAX_REQUESTS` (`1000`), `PHP_FPM_LISTEN`
(`0.0.0.0:9000`), `PHP_FPM_STATUS_PATH` (`/fpm-status`), `PHP_FPM_ACCESS_LOG` (`/proc/self/fd/2`),
`PHP_FPM_SLOWLOG_TIMEOUT` (`10s`). `PHP_FPM_MAX_CHILDREN`, `PHP_FPM_START_SERVERS`,
`PHP_FPM_MIN_SPARE` and `PHP_FPM_MAX_SPARE` are autotuned from the container memory limit and
`PHP_FPM_WORKER_MEMORY` (default `64` MB per worker). A value you set is used exactly and the
others adjust to stay consistent. Without a memory limit the entrypoint assumes 512 MB and says so.
The full variable reference and the autotuning rules are in the
[README](https://github.com/LotusWebAgency/php#configuration).

### Read-only root filesystem

`fpm`, `cli` and `cli-builder` run with a read-only root and one writable mount, `/tmp`:

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    read_only: true
    tmpfs:
      - /tmp:size=256m
    environment:
      PHP_EXT_ENABLE: ldap,uuid
```

`/tmp` holds sessions, upload temp files and the env-driven ini (written to a private mode-0700
directory when `conf.d` is not writable). Size it for your largest upload times concurrent uploads,
plus sessions. It counts against the container memory limit. `cli-builder` needs
`/tmp:exec,size=256m` because `npx` runs packages from `/tmp`.

Without a writable `/tmp`, `PHP_EXT_ENABLE` and `PHP_SNUFFLEUPAGUS` refuse to start the container,
and the other `PHP_*` ini variables are ignored with a warning naming each one. Your application's
own writes (PrestaShop `var/cache`, Laravel `storage`, WordPress uploads) need their own volume. A
FastCGI unix socket needs a writable directory. `docker exec <container> php ...` does not see the
env-driven ini; use `docker exec <container> docker-php-entrypoint php ...`. Details:
[README](https://github.com/LotusWebAgency/php#read-only-root-filesystem).

## Hardened deployment

The image is already non-root, with setuid bits stripped, ELF-hardened binaries and a baked
`disable_functions` list. A production `fpm` container adds the controls below. Together they leave
the worker processes with an empty capability set and `NoNewPrivs`, while the container still starts
healthy and serves requests.

```yaml
services:
  php:
    image: registry.example.com/myapp:1.0     # built from lotuswebagency/php, see below
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=256m
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    pids_limit: 256
    mem_limit: 1g                             # also sizes the FPM pool and opcache
    environment:
      PHP_SNUFFLEUPAGUS: laravel              # default | wordpress | prestashop | laravel | your own
      PHP_OPCACHE_JIT: disable                # Snuffleupagus turns the JIT off; this drops the warning
      PHP_OPCACHE_VALIDATE_TIMESTAMPS: "0"    # the code never changes inside the container
    volumes:
      - storage:/app/storage                  # only the application's own writable paths
    networks: [backend]                       # reachable by the web server only
volumes:
  storage:
networks:
  backend:
    internal: true
```

Bake the code into the image and make it root-owned, so `www-data` can read but not modify it.
`COPY --from` keeps the build stage's owner (UID 33 here), hence `--chown=root:root`:

```dockerfile
FROM lotuswebagency/php:8.5-cli-builder AS build
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --no-interaction
COPY . .
RUN composer dump-autoload --no-dev --classmap-authoritative

FROM lotuswebagency/php:8.5-fpm@sha256:...
COPY --from=build --chown=root:root /app /app
USER root
RUN mkdir -p /app/storage /app/bootstrap/cache \
 && chown -R www-data:www-data /app/storage /app/bootstrap/cache
USER www-data
```

A named volume mounted at `/app/storage` starts with the image's contents and owner. A bind mount of
the code (`./:/app:ro`) works too, with `:ro`.

What each setting needs to know:

- **`read_only` and `/tmp`.** `/tmp` is the only path the image writes. `noexec` is fine for `fpm`
  and `cli`; `cli-builder` needs `exec` for `npx`. Without a writable `/tmp`, `PHP_SNUFFLEUPAGUS` and
  `PHP_EXT_ENABLE` refuse to start. See [Read-only root filesystem](https://github.com/LotusWebAgency/php#read-only-root-filesystem).
- **`cap_drop: [ALL]`.** Nothing in `fpm` or `cli` needs a capability. The FPM master already runs as
  `www-data`, so the log notes that the pool's `user` and `group` lines are ignored; that is expected.
  Keep `PHP_FPM_LISTEN` on a port above 1024.
- **`no-new-privileges`.** No setuid binary is left to gain privileges with; this closes the path for
  anything added later.
- **Snuffleupagus.** Pick the ruleset that matches the application, or start a custom one from
  `default` (see [Hardening](https://github.com/LotusWebAgency/php#hardening)). Rulesets are for serving: run Composer and other build
  steps in `cli-builder` without one. Snuffleupagus hooks the executor, so PHP turns the JIT off
  while it is loaded and logs a startup warning. `PHP_OPCACHE_JIT=disable` says so up front and
  removes the warning; `off` does not, because it keeps the JIT buffer.
- **`PHP_DISABLE_FUNCTIONS`.** Adds names to the baked list and a mounted ini's, for example
  `proc_open` when the application never starts processes. Laravel queues, Symfony Process and
  Composer need `proc_open`. It refuses to start if a name does not end up disabled.
- **Limits.** `pids_limit` bounds runaway forks; the memory limit bounds the container and drives FPM
  and opcache autotuning (512 MB is assumed without one).
- **Network.** `fpm` speaks FastCGI on 9000 and should only be reachable by the web server. Never
  publish 9000 to the host.
- **Errors.** `PHP_DISPLAY_ERRORS` stays `Off` (the default); errors go to stderr.

The `docker run` flags and the Kubernetes `securityContext` for the same setup are in the
[README](https://github.com/LotusWebAgency/php#hardened-deployment).

## Extensions

73 extensions, defined in
[`php/ext.json`](https://github.com/LotusWebAgency/php/blob/main/php/ext.json); 72 are built (`imap`
is registered but not built: Wolfi has no c-client library).

**53 are compiled in**: the usual core set plus `igbinary`, `redis`, `imagick`, `memcached`, `apcu`
and `zstd`. **19 are shared modules**, loaded with `PHP_EXT_ENABLE`: `amqp`, `brotli`, `bz2`,
`event`, `ffi` (7.4+), `ldap`, `lz4`, `mcrypt` (7.x), `mongodb` (8.1+), `msgpack`,
`pcov` (7.1+), `protobuf` (8.2+), `snuffleupagus` (7.2+), `swoole` (8.2+), `tidy`,
`uuid`, `xdebug`, `xmlrpc` (7.x), `yaml`. An unknown or unavailable name is refused with a list of
what the image has.

`imagick` reads HEIC and AVIF (static libheif, libde265 and dav1d inside ImageMagick) but does not
write them. There is no `ssh2` extension: use [phpseclib](https://phpseclib.com/) for SSH and SFTP,
or compile `ssh2` in an `ext-builder` stage.

### Adding your own extension

The images carry no `pecl`, `pear` or `docker-php-ext-install`. Compile in an `ext-builder` stage and
copy only the `.so`:

```dockerfile
FROM lotuswebagency/php:8.5-ext-builder AS ext
ARG MYEXT_VERSION=1.2.3
ARG MYEXT_SHA256=<sha256 of the tarball>
RUN apk add --no-cache libmyext-dev
RUN set -eux; \
    curl -fsSLo /tmp/myext.tgz "https://example.com/myext-${MYEXT_VERSION}.tgz"; \
    echo "${MYEXT_SHA256}  /tmp/myext.tgz" | sha256sum -c -; \
    mkdir /src; \
    tar -xzf /tmp/myext.tgz -C /src --strip-components=1; \
    cd /src; \
    phpize; \
    ./configure; \
    make -j"$(nproc)"; \
    make install INSTALL_ROOT=/out

FROM lotuswebagency/php:8.5-fpm
COPY --from=ext /out/ /
USER root
RUN apk add --no-cache libmyext
USER www-data
ENV PHP_EXT_ENABLE=myext
```

- Use the same PHP version tag in both stages, ideally pinned by digest. An extension built for one
  PHP minor does not load in another. For a `-v3` runtime use `ext-builder-v3`.
- Install runtime libraries (not `-dev` packages) in the final stage as root, then switch back to
  `www-data`.
- Package names are Wolfi's, not Debian's: `apk search` finds one by name, and
  `apk info -W /usr/lib/libfoo.so.1` names the package that owns a file. On 8.1 and later PHP uses
  OpenSSL 4, so the header package is `openssl-4.0-dev`. `openssl-dev` is the OpenSSL 3 package and conflicts with it.
- For a `zend_extension` other than xdebug, opcache or snuffleupagus, put a
  `zend_extension=myext.so` file in `/usr/local/etc/php/conf.d/` instead of using `PHP_EXT_ENABLE`.

## Hardening

Measured on the shipped ELF binaries, not assumed from compiler flags: PIE, full RELRO
(`GNU_RELRO` and `BIND_NOW`), non-executable stack, `-fstack-protector-strong`,
`_FORTIFY_SOURCE=3`, and `-fcf-protection=full` on amd64. On arm64, PAC and BTI
(`-mbranch-protection=standard`) are compiled in; on PHP 7.0-8.4 (gcc, gold) BTI is not enforced at
runtime, because gold writes no `PT_GNU_PROPERTY` header and glibc enforces BTI from it. The compilers
also run with zero-initialized locals, no null-check deletion, wrapping signed overflow and no strict
aliasing. Links use packed relative relocations
(`-z pack-relative-relocs`, `DT_RELR`) where the linker supports it. Every setuid and setgid bit
inherited from the base image is stripped. Busybox's network applets (`ping`, `netstat`,
`traceroute`, `arping`, `microcom` and the rest of the raw-socket and interface set) are removed;
`curl` stays. A derived image that runs `apk add` gets the busybox links back and can prune them
again. PHP 7.0-8.4 build with GCC 16.2 (PGO, no LTO) and 8.5 with clang 19 (PGO
and ThinLTO), both from Wolfi packages.

Snuffleupagus is compiled in but off. `PHP_SNUFFLEUPAGUS=<ruleset>` turns it on. For your own
rules, mount `/usr/local/etc/php/snuffleupagus/<name>.rules` read-only and set `PHP_SNUFFLEUPAGUS=<name>`
(lowercase, digits, `-`, `_`; never a path). A custom file replaces the baked one; copy `default.rules`
to start. Laravel's `schedule:run` works under every ruleset. `sp.xxe_protection` is
off: it does not hold across requests, and on PHP 7 it disables your own `libxml_disable_entity_loader(true)`.

## Verifying images

Every published digest has an SBOM, max-mode SLSA provenance, a keyless Cosign signature, signed test
results, and OpenVEX statements where an accepted finding applies (currently `cli-builder`).

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

Use cosign 3. Signatures and attestations are created in the GHCR staging repository
`ghcr.io/lotuswebagency/php/release` and copied to Docker Hub with the image, digest for digest,
before any tag moves, so they verify on `lotuswebagency/php`. The test-result and OpenVEX attestation
commands and the details of what each contains are in the
[README](https://github.com/LotusWebAgency/php#verifying-images).

CI verifies the base image's Chainguard cosign signature before building on it, and every image
carries `org.opencontainers.image.base.name` and `org.opencontainers.image.base.digest` labels.

Pull requests and `develop` pushes build and test without publishing to Docker Hub. A Trivy gate
fails the build on any fixable CRITICAL or HIGH finding and reports none for any flavor. Two
findings are accepted, both without an upstream fix: CVE-2026-93687 (braces 3.0.3 in `cli-builder`'s
semantic-release, HIGH) and CVE-2026-15534 (perl 5.44.0 in `ext-builder`, MEDIUM); see
[Accepted findings](https://github.com/LotusWebAgency/php/blob/main/SECURITY.md#accepted-findings).
They are suppressed through the `.trivyignore` generated from `vex/php.openvex.json`, so a scan
without that file shows them. Trivy reads the apk database, so it cannot see libraries built from source and
linked statically or kept under `/opt`: ImageMagick (with static libheif, libde265 and dav1d) in
every image, OpenSSL 1.1.1w, ICU,
libxml2 and libxslt in the 7.0-8.0 builds (the last two are Debian trixie's 2.9.14 and 1.1.35 with
Debian's security patches), curl in 7.0-7.2. Those are tracked by hand through `deps/versions.lock`, as are the
`mariadb-dump`, `mariadb-admin` and `mariadb-check` binaries copied into the image. Reporting
channel: [SECURITY.md](https://github.com/LotusWebAgency/php/blob/main/SECURITY.md).

Two further gates fail the build on any finding in CISA's Known Exploited Vulnerabilities catalog, fixed or not, and on any AGPL-licensed package.

## Moving from a Debian or Alpine base

This applies to any PHP image built on Debian (the official `php:*-fpm` images, and
`dementev/php-fpm-with-ext` for 8.1 and later) or on Alpine (`dementev/php-fpm-with-ext` for
7.0-8.0). The notes below are written for Debian. Alpine users already have apk, but move from musl
to glibc, so rebuild every compiled extension in an `ext-builder` stage of the same tag.

- `apt-get install` becomes `apk add --no-cache`, run as root. There is no `apt-get` or `dpkg`, and
  package names differ (`libjpeg-dev` is `libjpeg-turbo-dev`, `libtiff-dev` is `tiff-dev`,
  `libxslt1-dev` is `libxslt-dev`, `uuid-dev` is `util-linux-dev`, `libpq-dev` is
  `postgresql-18-dev`).
- The amd64 baseline needs `x86-64-v2`. `-v3` tags refuse to start below `x86-64-v3`.
- PHP 8.1 to 8.5 use OpenSSL 4 (Debian-based images ship OpenSSL 3). Rebuild extensions compiled
  against `libssl.so.3` in an `ext-builder` stage of the same tag.
- `mysql*` names are wrappers around the MariaDB 13.1 `mariadb*` tools.
- Libraries are in `/usr/lib`, not `/usr/lib/x86_64-linux-gnu`. `ldd`, `getent`, `useradd` and
  `groupadd` are absent; list a binary's libraries with the loader
  (`/lib64/ld-linux-x86-64.so.2 --list <file>`, `/lib/ld-linux-aarch64.so.1` on arm64).

Full notes: [README](https://github.com/LotusWebAgency/php#moving-from-a-debian-or-alpine-base).

## Related images

| Image | Role |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) | Reverse proxy and TLS terminator |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) | Static sites and SPAs behind that proxy |
| **[`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php)** (this image) | PHP 7.0 to 8.5 compiled from source with PGO, hardened |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) | Percona Server for MySQL 8.4 LTS |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) | Adminer 6 with every supported driver |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). Issues and pull requests:
[github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).

Packaging in this repository is MIT licensed. PHP and the bundled extensions keep their own upstream
licenses.
