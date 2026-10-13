# php: PHP 7.0-8.5, compiled from source, PGO-trained on real apps

PHP 7.0 through 8.5, compiled from source on `debian:trixie-slim` with profile-guided optimization
(PGO) trained on real PrestaShop, WordPress, Laravel, Symfony and Drupal applications. Binaries are
hardened at the ELF level, Snuffleupagus virtual patching is available, and a read-only root
filesystem is supported.

Source and full docs: [github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Replaces `dementev/php-fpm-with-ext`
([migration notes](https://github.com/LotusWebAgency/php#migrating-from-php-fpm-with-ext)).

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

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every published image. |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | Built for `x86-64-v3` / `armv9-a`. 8.4 and 8.5 only, not `ext-builder`. |
| `{version}`, `latest` | `8.5`, `latest` | The default version's `fpm` image. |
| `{release}-{flavor}[-v3]` | `8.5.11-fpm` | Full patch version, read from the built image after tests and the Trivy gate. |

`-v3` needs a newer CPU. On older amd64 the image refuses to start (glibc prints
`CPU ISA level is lower than required`, exit 127). On arm64 there is no check and an unsupported core
gets SIGILL: `armv9-a` code needs Neoverse N2/V2-class cores (Graviton4, Axion, Cobalt 100, Grace),
not Graviton2/3, Ampere Altra or Apple silicon. Use the baseline tag on a Mac.

`8.4-fpm` moves with each 8.4 patch release. Pin the digest for reproducible builds.

## Flavors

| Flavor | Contents |
|---|---|
| `fpm` | PHP-FPM on `:9000` for a FastCGI-speaking reverse proxy. `STOPSIGNAL SIGQUIT` and a FastCGI `HEALTHCHECK` that needs no web server. |
| `cli` | `php -a` by default. Scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, the MariaDB client, Node.js 24 LTS with npm and corepack, semantic-release and Composer. No compiler. For build stages. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev and the PHP headers with `phpize`. Runs as root. For build stages. |

All images run `tini` as PID 1. All but `ext-builder` run as `www-data` (UID 33).

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
| `PHP_DISABLE_FUNCTIONS` | fpm: `passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec`. cli, ext-builder: unset; the same list is baked into `10-php.ini`. cli-builder: none | Adds to the baked list, never replaces it. `proc_open` stays enabled for Composer and `symfony/process`. |
| `PHP_OPCACHE_ENABLE` | `1` | `opcache.enable` |
| `PHP_OPCACHE_MEMORY` | one eighth of the container memory limit, 64-512 MB | `opcache.memory_consumption` |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS`, `PHP_OPCACHE_REVALIDATE_FREQ` | `1`, `2` | Set validation to `0` when deploys replace the whole tree. |
| `PHP_OPCACHE_PRELOAD` | unset | `opcache.preload` |
| `PHP_OPCACHE_JIT`, `PHP_OPCACHE_JIT_BUFFER` | `tracing`, `64M` | PHP 8+ only. |
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

## Extensions

75 extensions, defined in
[`php/ext.json`](https://github.com/LotusWebAgency/php/blob/main/php/ext.json); 74 are built (`imap`
is registered but not built: Debian trixie has no `libc-client-dev`).

**53 are compiled in**: the usual core set plus `igbinary`, `redis`, `imagick`, `memcached`, `apcu`
and `zstd`. **21 are shared modules**, loaded with `PHP_EXT_ENABLE`: `amqp`, `brotli`, `bz2`,
`event`, `ffi` (7.4+), `ldap`, `lz4`, `mcrypt` (7.x), `mongodb` (8.1+), `msgpack`,
`pcov` (7.1+), `protobuf` (8.2+), `snmp`, `snuffleupagus` (7.2+), `ssh2`, `swoole` (8.2+), `tidy`,
`uuid`, `xdebug`, `xmlrpc` (7.x), `yaml`. An unknown or unavailable name is refused with a list of
what the image has.

### Adding your own extension

The images carry no `pecl`, `pear` or `docker-php-ext-install`. Compile in an `ext-builder` stage and
copy only the `.so`:

```dockerfile
FROM lotuswebagency/php:8.5-ext-builder AS ext
ARG MYEXT_VERSION=1.2.3
ARG MYEXT_SHA256=<sha256 of the tarball>
RUN apt-get update && apt-get install -y --no-install-recommends libmyext-dev
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
RUN apt-get update && apt-get install -y --no-install-recommends libmyext1 \
    && rm -rf /var/lib/apt/lists/*
USER www-data
ENV PHP_EXT_ENABLE=myext
```

- Use the same PHP version tag in both stages, ideally pinned by digest. An extension built for one
  PHP minor does not load in another.
- Install runtime libraries (not `-dev` packages) in the final stage as root, then switch back to
  `www-data`.
- For a `zend_extension` other than xdebug, opcache or snuffleupagus, put a
  `zend_extension=myext.so` file in `/usr/local/etc/php/conf.d/` instead of using `PHP_EXT_ENABLE`.

## Hardening

Measured on the shipped ELF binaries, not assumed from compiler flags: PIE, full RELRO
(`GNU_RELRO` and `BIND_NOW`), non-executable stack, `-fstack-protector-strong`,
`_FORTIFY_SOURCE=3`, and `-fcf-protection=full` on amd64. Every setuid and setgid bit inherited from
the base image is stripped.

Snuffleupagus virtual patching is compiled in but not loaded. `PHP_SNUFFLEUPAGUS=prestashop` (or
`default`, `wordpress`, `laravel`) turns it on. For your own rules, mount
`/usr/local/etc/php/snuffleupagus/<name>.rules` read-only and set `PHP_SNUFFLEUPAGUS=<name>` (lowercase
letters, digits, `-` and `_`; a path is refused). A custom file replaces the baked ruleset, so start
from a copy of `default.rules`. `sp.xxe_protection` is off: it does not hold across requests, and on
PHP 7 it disables your own `libxml_disable_entity_loader(true)`.

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

Pull requests and `develop` pushes build and test without publishing to Docker Hub. A Trivy gate
fails the build on any fixable CRITICAL or HIGH finding. Trivy cannot see libraries built from source
under `/opt` (ImageMagick and net-snmp everywhere, OpenSSL and ICU in the 7.0-8.0 builds, curl in
7.0-7.2); those are tracked through `deps/versions.lock`. Reporting channel:
[SECURITY.md](https://github.com/LotusWebAgency/php/blob/main/SECURITY.md).

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
