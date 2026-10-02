# php — PHP 7.0–8.5, compiled from source, PGO-trained on real apps

PHP 7.0 through 8.5, compiled from source rather than installed from a distro
package, with a per-era compiler and profile-guided optimization trained on
real PrestaShop, WordPress, Laravel and Symfony applications instead of a
synthetic benchmark. Hardened at the ELF level (PIE, full RELRO, non-exec
stack, stack-protector, `_FORTIFY_SOURCE=3`, CF-protection), with
Snuffleupagus virtual patching available and read-only-rootfs deployment
supported out of the box.

Source and full docs:
[github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Replaces `dementev/php-fpm-with-ext`.

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    volumes:
      - ./:/app
```

## Why build from source

- **A compiler chosen per PHP era**: PHP 7.0–8.4 build with **GCC 16.2**,
  PGO, **no LTO** — GCC's LTRANS pass rejects the HYBRID VM's global
  register variables. PHP 8.5 builds with Debian's **clang 19**, PGO +
  **ThinLTO**, for the **TAILCALL VM** clang alone supports on this
  toolchain.
- **PGO trained on real applications, per tier** (the tier with the
  greatest PHP floor at or below each version): PrestaShop 9.2.0 + Laravel
  12.12.2 + Symfony 7 + WordPress 7.0.6 for PHP 8.2–8.5, down to PrestaShop
  1.6.1.24 + Laravel 5.5.28 + Symfony 3.4 + WordPress 6.5.12 for PHP 7.0.
  Full pinning: `php/pgo/corpus.lock` in the source repo.
- **Hardening measured on the shipped binaries**, not just asserted as
  compiler intent — see below.

## Tags

| PHP | Compiler | `-v3` | Support | EOL date |
|---|---|---|---|---|
| `7.0`–`7.4`, `8.0`, `8.1` | gcc | — | end-of-life | see [Support and EOL](#support-and-eol) |
| `8.2`, `8.3` | gcc | — | security | see below |
| `8.4` | gcc | yes | active | 2028-12-31 |
| `8.5` | clang | yes | active | 2029-12-31 |

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every published image (`fpm`, `cli`, `cli-builder`, `ext-builder`). |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | `x86-64-v3` / `armv9-a`, 8.4 and 8.5 only, not for `ext-builder`. Older CPUs can't run it — on arm64 that means anything before Neoverse N2/V2 (Graviton4 yes, Graviton2/3 no). Not for Apple silicon either: M4–M6 have no SVE outside SME streaming mode, so `-v3` dies with SIGILL in Docker Desktop. Use the baseline tag on a Mac. |
| `{version}` and `latest` | `8.5`, `latest` | The default version's `fpm` image only. |
| `{release}-{flavor}[-v3]` | `8.5.11-fpm`, `8.5.11-ext-builder`, `8.4.26-cli-v3` | Full patch version, pinned. Read from the built image (`PHP_VERSION`) and required to match `matrix.json`, so the tag can't claim a version the image doesn't contain. |

Version tags are read out of the built image after tests and the Trivy gate,
never out of the Dockerfile. `linux/amd64` and `linux/arm64`, SBOM, max-mode
build provenance and a keyless Cosign signature on every published digest.

## Flavors

| Flavor | What it is |
|---|---|
| `fpm` | PHP-FPM on `:9000`, behind nginx / Angie / any FastCGI-speaking proxy. `STOPSIGNAL SIGQUIT`, a FastCGI-native `HEALTHCHECK`. |
| `cli` | `php -a` by default — one-shot scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, the MariaDB client, Node.js 24 LTS with npm/corepack, semantic-release and Composer. No compiler. Meant for a build stage, not for runtime. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev and the PHP headers with `phpize`/`php-config`, for compiling your own extension and copying the `.so` into `fpm`/`cli` of the same version — see [Adding your own extension](#adding-your-own-extension). Runs as root; no Composer, no Node.js. Meant for a build stage, not for runtime. |

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
  nginx:
    image: lotuswebagency/nginx:latest
    depends_on: [php]
```

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

Every variable is validated at startup — a newline in the value, or a
set-but-empty value, refuses to start with a named reason.

| Variable | Default | Purpose |
|---|---|---|
| `PHP_MEMORY_LIMIT` | fpm `256M` · cli, ext-builder `512M` · cli-builder `-1` | `memory_limit`; unset keeps the flavor's baked value. |
| `PHP_MAX_EXECUTION_TIME` / `PHP_MAX_INPUT_TIME` / `PHP_MAX_INPUT_VARS` | `300` (cli, cli-builder, ext-builder: `0`) / `120` / `10000` | Execution limits. |
| `PHP_UPLOAD_MAX_FILESIZE` / `PHP_POST_MAX_SIZE` | `128M` / `128M` | Upload limits. |
| `PHP_TIMEZONE` | _(unset)_ | `date.timezone`. |
| `PHP_DISPLAY_ERRORS` | `Off` | Errors always go to stderr regardless. |
| `PHP_DISABLE_FUNCTIONS` | `passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec` | **Adds to** the baked list, never replaces it. `proc_open` is deliberately never disabled — Composer and `symfony/process` need it. |
| `PHP_OPCACHE_ENABLE` / `_MEMORY` / `_VALIDATE_TIMESTAMPS` / `_JIT` | `1` / autotuned 64–512 MB / `1` / `tracing` | OPcache tuning. |
| `PHP_EXT_ENABLE` | _(unset)_ | Comma-separated shared extensions to turn on, e.g. `ldap,uuid` — see below. |
| `PHP_SNUFFLEUPAGUS` | _(unset)_ | `default` / `wordpress` / `prestashop` / `laravel`, or the name of a custom ruleset you mounted — loads that virtual-patching ruleset. |
| `PHP_CHMOD_SHIM` | `0` | `true` enables the PrestaShop `chmod(0)` cache-bug workaround shim. |
| `PHP_FPM_PM` / `_MAX_REQUESTS` / `_LISTEN` / `_STATUS_PATH` / `_ACCESS_LOG` / `_SLOWLOG_TIMEOUT` | `dynamic` / `1000` / `0.0.0.0:9000` / `/fpm-status` / `/proc/self/fd/2` / `10s` | `fpm` flavor pool config. |
| `PHP_FPM_MAX_CHILDREN` (+ `_START_SERVERS` / `_MIN_SPARE` / `_MAX_SPARE`) | autotuned from the container's memory limit | Pool sizing — any one you set is honored exactly; the rest move to stay consistent. |

**Read-only rootfs is supported**: `docker run --read-only --tmpfs /tmp …`
still autotunes the pool and applies `PHP_EXT_ENABLE`/ini overrides, falling
back to a private, mode-0700 directory under `/tmp` where needed.

## Extensions

75 total. **53 compiled in statically** (bcmath, curl, gd, intl, mbstring,
mysqli, opcache, openssl, pdo\_\*, redis, imagick, memcached, apcu, zstd,
soap, sodium, zip, and more — full list in the source repo's README).

**22 ship as shared modules**, opt-in via `PHP_EXT_ENABLE`: `amqp`,
`brotli`, `bz2`, `event`, `ffi`, `imap` (removed from core in 8.4), `ldap`,
`lz4`, `mcrypt` (7.x only, needed by PrestaShop 1.6), `mongodb` (≥8.1), `msgpack`, `pcov`,
`protobuf` (≥8.2), `snmp`, `snuffleupagus`, `ssh2`, `swoole` (≥8.2), `tidy`,
`uuid`, `xdebug` (always available), `xmlrpc` (removed from core in 8.0),
`yaml`.

### Adding your own extension

No `pecl`, `pear` or `docker-php-ext-install` in the images. Compile in an
`ext-builder` stage (`cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev,
the PHP headers, `phpize` and `php-config`) and copy only the `.so` into `fpm`
or `cli`:

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

- Use the **same PHP version tag** (ideally the same digest) for `ext-builder`
  and the runtime stage: the extension directory carries the Zend module API
  number, and an extension built for one PHP minor does not load in another.
- Fetch a source tarball and verify its checksum; there is no `pecl install`.
- Runtime libraries must be `apt-get install`ed in the final stage **as root**
  (the images run as UID 33) — the shared libraries, not the `-dev` packages.
- `PHP_EXT_ENABLE` works for any `.so` in the extension directory; for a
  `zend_extension` other than xdebug/opcache/snuffleupagus, drop a
  `zend_extension=myext.so` ini file into `/usr/local/etc/php/conf.d/`.
- `ext-builder` runs as root, has no Composer or Node.js, and has no `-v3`
  variant (an extension built against baseline headers loads in `-v3` too).

## Hardening

Measured on the shipped ELF binaries, not just asserted as compiler intent:
**PIE**, **full RELRO** (`GNU_RELRO` + `BIND_NOW`), **non-executable
stack**, **stack canaries** (`-fstack-protector-strong`),
**`_FORTIFY_SOURCE=3`**, and **`-fcf-protection=full`** (`endbr64` landing
pads on amd64). Every setuid/setgid bit inherited from the base image is
stripped.

**Snuffleupagus** virtual patching ships compiled but never loaded —
`PHP_SNUFFLEUPAGUS=prestashop` (or `default`/`wordpress`/`laravel`) turns
it on.
To use your own rules, mount
`/usr/local/etc/php/snuffleupagus/<name>.rules` read-only and set
`PHP_SNUFFLEUPAGUS=<name>` (lowercase letters, digits, `-` and `_`, starting
with a letter or digit; anything else, including a path, is refused). Start
from a copy of `default.rules`. The XXE feature (`sp.xxe_protection`) is not
enabled: it does not hold across requests, and on PHP 7 it would nop your own
`libxml_disable_entity_loader(true)`.

## Measured performance

nginx → FastCGI → FPM, `pm=static` with 8 workers, FPM limited to 2 CPU cores,
opcache on, JIT off, k6 measuring time to first byte on a PrestaShop shop, 5
rotated rounds per run, two independent runs. "Stock" is
`dementev/php-fpm-with-ext` on the same PHP minor. Absolute numbers depend on
the host; the deltas are the point.

- **PHP 8.5** (clang 19, PGO + ThinLTO, TAILCALL VM) vs. stock, PrestaShop
  9.1.5: +10–11% max requests/sec, TTFB p50 −9% at saturation, −9 to −12% at a
  fixed rate, p95 −16%.
- **PHP 8.4** (GCC 16.2, PGO, no LTO, HYBRID VM) vs. stock, PrestaShop 8.2.7:
  +5–6% max requests/sec, TTFB p50 −5% at saturation, −7 to −8% at a fixed
  rate, p95 −8 to −9%.

Method and per-run numbers:
[README](https://github.com/LotusWebAgency/php#measured-performance).

## Support and EOL

| PHP | Support | EOL date |
|---|---|---|
| 7.0 | end-of-life | 2019-01-10 |
| 7.1 | end-of-life | 2019-12-01 |
| 7.2 | end-of-life | 2020-11-30 |
| 7.3 | end-of-life | 2021-12-06 |
| 7.4 | end-of-life | 2022-11-28 |
| 8.0 | end-of-life | 2023-11-26 |
| 8.1 | end-of-life | 2025-12-31 |
| 8.2 | security | 2026-12-31 |
| 8.3 | security | 2027-12-31 |
| 8.4 | active | 2028-12-31 |
| 8.5 | active | 2029-12-31 |

Straight from [php.net's supported-versions page](https://www.php.net/supported-versions.php),
not this project's opinion. End-of-life tags are still published and still
rebuilt weekly for base-image/package security updates — the PHP
interpreter itself just receives no further upstream fixes. Full policy:
[SUPPORT.md](https://github.com/LotusWebAgency/php/blob/main/SUPPORT.md).

## Verifying images

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

A pull request or a push to `develop` builds and tests without publishing; a Trivy gate fails the
build on any fixable CRITICAL or HIGH finding before anything reaches a
registry. Trivy scans the Debian package layer -- it can't see the statically
linked libraries (OpenSSL, ICU and similar) vendored into the 7.0–8.0 builds,
which are tracked through `deps/versions.lock`'s pins instead.
[SECURITY.md](https://github.com/LotusWebAgency/php/blob/main/SECURITY.md)
has the reporting channel.

## Related images

One family, built by the same pipeline, meant to run together.

| Image | What it does |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) | Public-facing reverse proxy and TLS terminator |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) | Static sites and SPAs behind that proxy |
| **[`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php)** — this image | PHP 7.0 → 8.5 compiled from source with PGO, hardened |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) | Percona Server for MySQL 8.4 LTS, no root inside |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) | Adminer 6 with every driver, for reaching any of the above |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). These images are not a side
project — they are the base layer under the client and product systems we
run, which is why they are gated, tested and signed rather than pushed by
hand.

Issues and pull requests:
[github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Need this kind of infrastructure built or maintained for your own stack?
[lotuswebagency.com](https://lotuswebagency.com).

Packaging in this repository is MIT licensed. PHP and the bundled
extensions keep their own upstream licenses.
