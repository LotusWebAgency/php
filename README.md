# php

PHP 7.0 through 8.5, compiled from source rather than installed from a
distro package, with a per-era compiler and PGO trained on real PrestaShop,
WordPress, Laravel and Symfony applications instead of a synthetic
benchmark. Hardened at the ELF level (PIE, full RELRO, non-exec stack,
stack-protector, `_FORTIFY_SOURCE=3`, CF-protection), with Snuffleupagus
virtual patching available and read-only-rootfs deployment supported out of
the box.

Published as [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php),
source at [github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Replaces [`dementev/php-fpm-with-ext`](https://hub.docker.com/r/dementev/php-fpm-with-ext) —
see [Migrating from `php-fpm-with-ext`](#migrating-from-php-fpm-with-ext) below.

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    volumes:
      - ./:/app
```

## Why build from source

`docker-php-extension-installer` on top of the upstream `php` image gets you
a working PHP fast, but every extension is generic-tuned and the interpreter
itself is whatever `-O2` the upstream Debian/Alpine packagers shipped.  This
image compiles PHP itself, per version:

- **A compiler chosen per PHP era** (`matrix.json`'s `compiler` field): PHP
  7.0–8.4 build with **GCC 16.2**, PGO, no LTO — GCC's LTRANS pass rejects
  the HYBRID VM's global register variables
  (`ext/opcache/jit/zend_jit_vm_helpers.c`), so LTO is off there by design,
  not by omission. PHP 8.5 builds with Debian's **clang 19**, PGO +
  **ThinLTO**, for the **TAILCALL VM** clang alone supports on this
  toolchain. `-std=gnu17` is pinned on every version on both compilers — GCC
  15+'s `-std=gnu23` default silently changes K&R-style code that real
  php-src and PECL sources still contain.
- **Profile-guided optimization trained on real applications**, not a
  micro-benchmark. Each PGO training tier replays PrestaShop, WordPress and
  a Laravel app skeleton (a Symfony app too, pinned per tier) through
  `php-fpm` under the exact `conf/opcache.ini` this image ships, and the
  resulting profile is what the release build is compiled against
  (`php/pgo/corpus.lock`, `php/pgo/corpus/tiers`):

  | Tier floor | PrestaShop | Laravel | Symfony | WordPress |
  |---|---|---|---|---|
  | 8.2 (php 8.2–8.5) | 9.2.0 | 12.12.2 | 7 | 7.0.6 |
  | 8.1 (php 8.1) | 9.2.0 | 10.3.3 | 6.4 | 7.0.6 |
  | 7.2 (php 7.2–8.0) | 8.2.8 | 6.20.1 | 5.4 | 6.9.9 |
  | 7.1 (php 7.1) | 1.7.8.11 | 5.8.35 | 4.4 | 6.5.12 |
  | 7.0 (php 7.0) | 1.6.1.24 | 5.5.28 | 3.4 | 6.5.12 |

  A version belongs to the tier with the greatest floor at or below it, so
  every PHP 8.2–8.5 image, for instance, is trained on the same 9.2.0/12.12.2
  corpus. See [Measured performance](#measured-performance) for what this
  actually buys.
- **Hardening measured on the shipped binaries**, not just asserted as
  compiler intent — see [Hardening](#hardening).

## Tags

Every one of the 11 PHP versions ships all four flavors — `fpm`, `cli`,
`cli-builder`, `ext-builder` — for `linux/amd64` and `linux/arm64`:

| PHP | Release | Era | Compiler | `-v3` variant | Support | EOL date |
|---|---|---|---|---|---|---|
| `7.0` | 7.0.33 | legacy | gcc | — | end-of-life | 2019-01-10 |
| `7.1` | 7.1.33 | legacy | gcc | — | end-of-life | 2019-12-01 |
| `7.2` | 7.2.34 | legacy | gcc | — | end-of-life | 2020-11-30 |
| `7.3` | 7.3.33 | legacy | gcc | — | end-of-life | 2021-12-06 |
| `7.4` | 7.4.33 | legacy | gcc | — | end-of-life | 2022-11-28 |
| `8.0` | 8.0.30 | legacy | gcc | — | end-of-life | 2023-11-26 |
| `8.1` | 8.1.34 | modern | gcc | — | end-of-life | 2025-12-31 |
| `8.2` | 8.2.34 | modern | gcc | — | security | 2026-12-31 |
| `8.3` | 8.3.35 | modern | gcc | — | security | 2027-12-31 |
| `8.4` | 8.4.26 | modern | gcc | yes | active | 2028-12-31 |
| `8.5` | 8.5.11 | modern | clang | yes | active | 2029-12-31 |

`support` is one of `active`, `security` (upstream security fixes only) or
`end-of-life` (no upstream fixes at all); `eol_date` is upstream's own final
security-support-end date. Both come straight from `matrix.json` and are
carried onto every image as `com.lotuswebagency.support` /
`com.lotuswebagency.eol-date` labels — see
[Support and EOL](#support-and-eol) below.

Tag scheme (`scripts/gen_matrix.py`):

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every published image. |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | Compiled for `x86-64-v3` / `armv9-a` instead of the `x86-64`/`armv8-a` baseline — 8.4 and 8.5 only, and not for `ext-builder` (an extension built against baseline headers loads on the v3 runtime). Newer instruction set, older CPUs can't run it: pre-Haswell/Excavator on amd64; on arm64 anything before Neoverse N2/V2 (it runs on Graviton4, Google Axion, Azure Cobalt 100, NVIDIA Grace — not on Graviton2/3, Ampere Altra/AmpereOne or Apple silicon). Apple M4–M6 are armv9 chips but implement SVE only in SME streaming mode, and `armv9-a` code uses SVE2 in normal mode, so `-v3` dies with SIGILL in Docker Desktop, OrbStack and the like (which may still advertise `sve2` in `/proc/cpuinfo`). On a Mac, use the baseline tag. |
| `{version}` and `latest` | `8.5`, `latest` | The default version's (`matrix.json`'s `default_version`, currently 8.5) `fpm` image only. |
| `{release}-{flavor}[-v3]` | `8.5.11-fpm`, `8.5.11-ext-builder`, `8.4.26-cli-v3` | Full patch version, pinned. Read from the built image (`PHP_VERSION`) and required to match `matrix.json`, so the tag can't claim a version the image doesn't contain. |

Version tags are read out of the built image after tests and the Trivy gate,
never out of the Dockerfile — see [SUPPORT.md](SUPPORT.md) for the full
lifecycle policy and what "supported" means for the end-of-life tags below.

50 images ship in total: 11 versions × 4 flavors, +6 for the two `-v3`
variants (2 versions × 3 flavors; `ext-builder` has none).

## Flavors

| Flavor | What it is |
|---|---|
| `fpm` | PHP-FPM on `:9000`, behind nginx / Angie / another reverse proxy speaking FastCGI. `CMD php-fpm -F`, `STOPSIGNAL SIGQUIT` for a graceful worker drain, a FastCGI-native `HEALTHCHECK` (`php-fpm-healthcheck`, no front web server needed). |
| `cli` | `php -a` by default — one-shot scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, the MariaDB client (`mariadb`, `mariadb-dump`), Node.js 24 LTS with npm and corepack, [semantic-release](https://github.com/semantic-release/semantic-release), and [Composer](https://getcomposer.org/) (installed with the vendor's own signature verification). No compiler and no `phpize`: it is the asset/test/deploy stage. Meant for a build stage, not for runtime. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev and the PHP headers with `phpize`/`php-config`, for compiling your own extension and copying the `.so` into `fpm`/`cli` of the same PHP version — see [Adding your own extension](#adding-your-own-extension). Runs as root; no Composer, no Node.js. Meant for a build stage, not for runtime. |

## Quick start

**FPM behind a reverse proxy:**

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
    image: lotuswebagency/nginx:latest   # or dementev/angie, or your own
    depends_on: [php]
```

**CLI, one-shot:**

```sh
docker run --rm -v "$PWD:/app" -w /app lotuswebagency/php:8.5-cli php artisan queue:work --once
```

**`cli-builder`, as a multi-stage build stage:**

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

Everything the entrypoint reads is set once, before `exec`ing into the real
command — nothing is polled or re-read (`rootfs/usr/local/bin/docker-php-entrypoint`).
Every variable below is validated at startup: a newline embedded in the
value, or a value that is set-but-empty, refuses to start with a named
reason rather than silently falling back to the image default.

| Variable | Default | Purpose |
|---|---|---|
| `PHP_MEMORY_LIMIT` | fpm `256M` · cli and ext-builder `512M` · cli-builder `-1` | `memory_limit`. Unset keeps the flavor's baked value. |
| `PHP_MAX_EXECUTION_TIME` | fpm `300` · cli, cli-builder and ext-builder `0` (no limit) | `max_execution_time`. |
| `PHP_MAX_INPUT_TIME` | `120` | `max_input_time`. |
| `PHP_MAX_INPUT_VARS` | `10000` | `max_input_vars`. |
| `PHP_UPLOAD_MAX_FILESIZE` | `128M` | `upload_max_filesize`. |
| `PHP_POST_MAX_SIZE` | `128M` | `post_max_size`. |
| `PHP_TIMEZONE` | _(unset)_ | `date.timezone`. |
| `PHP_ERROR_REPORTING` | `E_ALL & ~E_DEPRECATED` | `error_reporting`. |
| `PHP_DISPLAY_ERRORS` | `Off` | `display_errors`. Errors always go to stderr regardless (`log_errors = On`, `error_log = /dev/stderr`). |
| `PHP_DISABLE_FUNCTIONS` | `passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec` | Adds to the baked list — never replaces it. `proc_open` is deliberately never disabled: Composer and `symfony/process` need it. The entrypoint verifies the union is actually in force (per fpm pool, or for the real command about to run) before starting, and refuses a name it cannot resolve to a real, currently-loaded function. |
| `PHP_OPCACHE_ENABLE` | `1` | `opcache.enable`. |
| `PHP_OPCACHE_MEMORY` | autotuned, clamped 64–512 MB | `opcache.memory_consumption`. Baked default is 192 MB; unset, the entrypoint derives ⅛ of the detected container memory limit. |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `1` | `opcache.validate_timestamps`. Set `0` in production once deploys replace the whole tree atomically. |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `2` | `opcache.revalidate_freq`. |
| `PHP_OPCACHE_PRELOAD` | _(unset)_ | `opcache.preload`. |
| `PHP_OPCACHE_JIT` | `tracing` | `opcache.jit`. PHP 8+ only; no-op on 7.x. |
| `PHP_OPCACHE_JIT_BUFFER` | `64M` | `opcache.jit_buffer_size`. |
| `PHP_EXT_ENABLE` | _(unset)_ | Comma-separated list of shared extensions to turn on — see [Extensions](#extensions). |
| `PHP_SNUFFLEUPAGUS` | _(unset)_ | Name of a ruleset (`default`, `wordpress`, `prestashop`, `laravel`, or a [custom one](#custom-rulesets) you mounted) to load — see [Hardening](#hardening). |
| `PHP_CHMOD_SHIM` | `0` | `1`/`true`/`yes`/`on` `LD_PRELOAD`s the PrestaShop `chmod(0)` cache-bug shim (see below); any other spelling than the accepted on/off ones refuses to start. |
| `PHP_INI_SCAN_DIR` | _(image default)_ | Standard PHP variable; setting it *replaces* the default scan path. The entrypoint always splices the baked conf.d and its own writable/private directory back in, unless you explicitly set it to the empty string (PHP's own "scan nothing"). |
| `PHP_FPM_PM` | `dynamic` | `fpm` flavor only. `pm`. |
| `PHP_FPM_MAX_CHILDREN` | autotuned from the container's memory limit | `pm.max_children`. Read from `/sys/fs/cgroup/memory.max`; with no limit detected, sizing assumes 512 MB and says so. |
| `PHP_FPM_START_SERVERS` / `PHP_FPM_MIN_SPARE` / `PHP_FPM_MAX_SPARE` | derived from `PHP_FPM_MAX_CHILDREN` | Same pool-size family; each is honored exactly as set and the other, unpinned ones move to stay consistent rather than refusing to start. |
| `PHP_FPM_MAX_REQUESTS` | `1000` | `pm.max_requests`. |
| `PHP_FPM_LISTEN` | `0.0.0.0:9000` | `listen`. |
| `PHP_FPM_STATUS_PATH` | `/fpm-status` | `pm.status_path`. `ping.path` is fixed at `/fpm-ping` (response `pong`) — that's what the built-in `HEALTHCHECK` speaks. |
| `PHP_FPM_ACCESS_LOG` | `/proc/self/fd/2` | `access.log`. |
| `PHP_FPM_SLOWLOG_TIMEOUT` | `10s` | `request_slowlog_timeout`. |
| `PHP_FPM_WORKER_MEMORY` | `64` (MB) | Per-worker memory assumption the pool autotuning divides the usable budget by. |

Do **not** set `PHP_FPM_MAX_CHILDREN_EFFECTIVE`/`_START_SERVERS_EFFECTIVE`/
`_MIN_SPARE_EFFECTIVE`/`_MAX_SPARE_EFFECTIVE` — those are the entrypoint's own
computed output (and the only pool variables `docker image inspect` shows);
the entrypoint overwrites them on every start and refuses to start if you set
one to something other than the image's own baked default, naming the real
knob to use instead.

### Read-only root filesystem

`fpm`, `cli` and `cli-builder` run with a read-only root filesystem and one
writable mount, `/tmp`:

```sh
docker run --read-only --tmpfs /tmp:size=256m lotuswebagency/php:8.5-fpm
```

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    read_only: true
    tmpfs:
      - /tmp:size=256m
    environment:
      PHP_MEMORY_LIMIT: 512M
      PHP_EXT_ENABLE: ldap,uuid
```

In Kubernetes the same shape should map to `readOnlyRootFilesystem: true` plus an
`emptyDir` mounted at `/tmp` (not exercised by our tests).

`/tmp` is the only path the image writes at runtime (checked with `docker
diff` after a full workload, and by `tests/test-readonly.sh` on every image):

- PHP sessions (`session.save_path` defaults to `/tmp`) and upload temp files
  (`upload_tmp_dir` defaults to `/tmp`). Size the tmpfs as your largest upload
  (`upload_max_filesize` is 128M) times the number of concurrent uploads, plus
  the session files. A tmpfs counts against the container's memory limit (an
  `emptyDir` with `medium: Memory` does too), so it has to fit inside that
  budget, not on top of it.
- The env-driven ini: when `conf.d` is not writable the entrypoint generates
  it in a private, mode-0700, `mktemp`-named directory under `/tmp`, so
  `PHP_MEMORY_LIMIT`, the opcache variables, `PHP_EXT_ENABLE` and
  `PHP_SNUFFLEUPAGUS` apply exactly as on a writable rootfs, and the FPM pool is
  still autotuned.
- `sys_get_temp_dir()`, `tempnam()`, Xdebug output and, in `cli-builder`, the
  Composer, npm and Corepack caches (`COMPOSER_HOME`, `npm_config_cache`,
  `COREPACK_HOME` already point into `/tmp`).

Nothing else needs a mount. FPM logs to stderr and writes no pid file; opcache
and the JIT live in shared memory; on PHP 7.x opcache's lock file goes to
`/dev/shm`, which Docker and Kubernetes both provide writable; net-snmp's
`/var/lib/snmp` is pre-created and stays untouched. For `fpm` and `cli` the tmpfs
may keep Docker's default `noexec`: nothing runs from `/tmp`. `cli-builder` is
the exception: `npx <package>` unpacks the package into `/tmp/npm/_npx` and runs
it from there, which fails with `EACCES` under `noexec`. Mount it executable,
`--tmpfs /tmp:exec,size=256m` (compose: `/tmp:exec,size=256m`).

What does not work read-only, and how it fails:

- **No writable `/tmp`.** `PHP_EXT_ENABLE` and `PHP_SNUFFLEUPAGUS` refuse to
  start the container rather than run without the extension or the ruleset.
  The other `PHP_*` ini variables are ignored with a warning that names the
  variable. Sessions and uploads fail with `Read-only file system` in the
  error log, not silently.
- **Your application's own writes** (PrestaShop's `var/cache`, Laravel's
  `storage`, WordPress uploads, `cli-builder`'s project directory for
  `composer install` / `npm install`) need a volume or tmpfs of their own.
- **A FastCGI unix socket** needs a writable directory: leave `PHP_FPM_LISTEN`
  on its TCP default or put the socket on a mount you provide.
- **`docker exec <container> php …`** does not see the env-driven ini (true
  on a writable rootfs too); use `docker exec <container> docker-php-entrypoint
  php …` to apply it.

### `PHP_EXT_ENABLE`

Every extension in the table below marked "shared" ships compiled but
dormant. Turn one on with:

```yaml
environment:
  PHP_EXT_ENABLE: "ldap,uuid"
```

`php-ext-enable` (the script behind this) refuses an unknown name loudly,
listing what's actually available in the image, rather than doing nothing.
xdebug and snuffleupagus load as Zend extensions automatically — you don't
need to spell that out.

## Extensions

75 extensions total, built through `php/ext.json` — the registry that
drives configure flags, the build, and the smoke test's own assertions.
**53 are compiled in statically** and need nothing to use:

```
bcmath, calendar, ctype, curl, dom, exif, fileinfo, filter, ftp, gd,
gettext, gmp, hash, iconv, intl, json, mbstring, mysqli, mysqlnd, opcache,
openssl, pcntl, pdo, pdo_mysql, pdo_pgsql, pdo_sqlite, pgsql, phar, posix,
readline, session, shmop, simplexml, soap, sockets, sodium, sqlite3,
sysvmsg, sysvsem, sysvshm, tokenizer, xml, xmlreader, xmlwriter, xsl, zip,
zlib, igbinary, redis, imagick, memcached, apcu, zstd
```

**22 ship as shared modules, opt-in via `PHP_EXT_ENABLE`:**

| Extension | PHP versions | Notes |
|---|---|---|
| `amqp` | ≥7.0 | RabbitMQ client for Laravel queues. |
| `brotli` | ≥7.0 | Response compression. |
| `bz2` | ≥7.0 | Legacy `.bz2` import archives. |
| `event` | ≥7.0 | libevent-backed async I/O. |
| `ffi` | ≥7.4 | Shipped disabled — it escapes every PHP-level sandbox. |
| `imap` | 7.0–8.3 | Removed from php-src core in 8.4. |
| `ldap` | ≥7.0 | Enterprise SSO auth. |
| `lz4` | ≥7.0 | Fast-compression session serializer. |
| `mcrypt` | 7.0–7.4 | Dead upstream after PHP 7. PrestaShop 1.6 needs it for its own cookies: enable it or the back office rejects every login. |
| `mongodb` | ≥8.1 | Driver's own configure refuses below 8.1. |
| `msgpack` | ≥7.0 | Compact queue serialization. |
| `pcov` | ≥7.1 | PHPUnit coverage driver. |
| `protobuf` | ≥8.2 | gRPC clients; pinned build refuses below 8.2. |
| `snmp` | ≥7.0 | Legacy server monitoring. Links a vendored, client-only net-snmp (`/opt/net-snmp`) instead of Debian's `libsnmp40t64`, which hard-depends on perl (~49 MB). The MIB files ship in `/opt/net-snmp/share/snmp/mibs` but none load automatically, as on Debian; set `MIBS=ALL` or `mibs +ALL` in `/etc/snmp/snmp.conf` to load them. The search path is Debian's (`$HOME/.snmp/mibs`, `/usr/share/snmp/mibs` and its `iana` and `ietf` subdirectories) plus the shipped directory, so MIBs mounted where they would be on a Debian host are found; `MIBDIRS` replaces it (prefix `+` to extend it) and `MIBS=+NAME` loads one. |
| `snuffleupagus` | ≥7.2 | Virtual patching — see [Hardening](#hardening). |
| `ssh2` | ≥7.0 | Deployment tooling SFTP/SSH. |
| `swoole` | ≥8.2 | Laravel Octane's async server; needs PHP Fibers. |
| `tidy` | ≥7.0 | Legacy HTML cleanup on import. |
| `uuid` | ≥7.0 | UUID primary keys without a pure-PHP fallback. |
| `xdebug` | ≥7.0 | Development-only debugging/profiling. **Always available**: an explicit requirement, enforced by a test, so no future pin bump silently drops it from any image. |
| `xmlrpc` | 7.0–7.x | Removed from core in PHP 8.0. |
| `yaml` | ≥7.0 | Symfony/Laravel config parsing without the Composer polyfill. |

A handful of extensions are version-gated because upstream itself gates
them (`imap` left core in 8.4, `xmlrpc` in 8.0, `mongodb`/`swoole`/`protobuf`
refuse to build below their stated floor) — `php-ext-enable` on an
unavailable name fails with the same "no such extension" message as a typo.

### Adding your own extension

The images carry no `pecl`, `pear` or `docker-php-ext-install`. An extension
that is not in the table above is compiled in a build stage with `ext-builder`
— `cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev and the PHP headers
with `phpize`/`php-config` — and only the resulting `.so` is copied into the
`fpm` or `cli` image:

```dockerfile
# 1. Compile. Same PHP version tag as the runtime stage below.
FROM lotuswebagency/php:8.5-ext-builder AS ext
ARG MYEXT_VERSION=1.2.3
ARG MYEXT_SHA256=<sha256 of the tarball>
# -dev packages the extension needs at build time go in this stage (root here).
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

# 2. Ship. Copy the .so (installed under /out at its real extension_dir path),
#    add the runtime libraries it links against, switch it on.
FROM lotuswebagency/php:8.5-fpm
COPY --from=ext /out/ /
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libmyext1 \
    && rm -rf /var/lib/apt/lists/*
USER www-data
ENV PHP_EXT_ENABLE=myext
```

- **One PHP version tag for both stages**, ideally pinned by digest
  (`lotuswebagency/php:8.5-ext-builder@sha256:…` and the same for `8.5-fpm`).
  The extension directory is named after the Zend module API number, and an
  extension compiled against one PHP minor does not load in another.
  `php-config --extension-dir` in `ext-builder` is the directory the `fpm`/`cli`
  image of that version loads from; `make install INSTALL_ROOT=/out` plus
  `COPY --from=ext /out/ /` puts the `.so` there without you spelling it out.
- **Fetch a source tarball and verify its checksum**, as above — there is no
  `pecl install` to do it for you.
- **Runtime libraries are yours to install.** The runtime images run as UID 33,
  so the final stage needs `USER root` for `apt-get install` and a `USER www-data`
  after it. Install the shared libraries (`libmyext1`), not the `-dev` packages.
- **`PHP_EXT_ENABLE=myext`** works for any `myext.so` in the extension
  directory. Only `xdebug`, `opcache` and `snuffleupagus` are known to be Zend
  extensions; for another `zend_extension`, drop a `zend_extension=myext.so`
  ini file into `/usr/local/etc/php/conf.d/` instead.
- `ext-builder` runs as root (it is a build stage; `make install` writes into
  the extension directory), has no Composer and no Node.js, and has no `-v3`
  variant: an extension built against the baseline headers loads in the `-v3`
  runtime too. The repository's own end-to-end test for this flow is
  `tests/test-ext-builder.sh` with the fixture in `tests/fixtures/ext-hello`.

## Hardening

**Every binary this image ships is verified, not just compiled with intent**
(`tests/assert-elf-hardening.sh` measures the produced ELF files directly):

- **PIE** (`ET_DYN`) — ASLR applies.
- **Full RELRO** — `GNU_RELRO` segment *and* `BIND_NOW`, so the GOT is
  resolved and mapped read-only before `main()` runs (partial RELRO, GOT
  still writable, is exactly what this rules out).
- **Non-executable stack** — `GNU_STACK` present, flags `RW` not `RWE`.
- **Stack canaries** (`-fstack-protector-strong`) — `__stack_chk_fail`
  present in the main binary's dynamic symbols.
- **`_FORTIFY_SOURCE=3`** — fortifiable libc calls resolve to `__*_chk`.
- **Control-flow integrity** (`-fcf-protection=full` on amd64) — every
  function entry carries an `endbr64` landing pad. The loader-enforced
  `.note.gnu.property` IBT/SHSTK marking is deliberately *not* asserted or
  claimed: it's absent from Debian trixie's own toolchain output entirely
  (checked against `/bin/ls`), so asserting it would fail on a correctly
  built image.
- `-Wl,-z,noexecstack`, `-Wl,--as-needed`, `-Wl,--build-id=sha1` on every
  link.

**Snuffleupagus** — [virtual patching](https://github.com/jvoisin/snuffleupagus)
ships compiled but never loaded by default. Four rulesets are baked into
`/usr/local/etc/php/snuffleupagus/`:

```yaml
environment:
  PHP_SNUFFLEUPAGUS: prestashop   # or: default, wordpress, laravel
```

The PrestaShop ruleset deliberately leaves `readonly_exec` off — enabling it
blocks PrestaShop's own cache-rebuild writes.

Snuffleupagus's XXE feature (`sp.xxe_protection`) is not enabled in any of
them. It turns libxml's entity loader off from an INI handler at startup, which
does not carry into requests, so `LIBXML_NOENT` still expands `file://`
entities with it on — and on PHP 7 it also nops the application's own
`libxml_disable_entity_loader(true)`. libxml2 ≥ 2.9 does not load external
entities unless the application opts in with `LIBXML_NOENT` / `LIBXML_DTDLOAD`;
on PHP 7, call `libxml_disable_entity_loader(true)` yourself.

Each ruleset runs its application unmodified: the exemptions it needs over
upstream's defaults (framework includes, WordPress's own loopback requests,
Symfony Console's terminal probe) are scoped to the framework file that makes
the call, not opened up for everyone. Rulesets are for serving; build and
deploy (Composer included) with `cli-builder` and no ruleset.

#### Custom rulesets

To run your own rules, mount the file read-only into the ruleset directory and
select it by name:

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    environment:
      PHP_SNUFFLEUPAGUS: my-site
    volumes:
      - ./my-site.rules:/usr/local/etc/php/snuffleupagus/my-site.rules:ro
```

`PHP_SNUFFLEUPAGUS` is a bare name, never a path: it must match
`^[a-z0-9][a-z0-9_-]*$` (lowercase letters, digits, `-` and `_`, starting with a
letter or digit), and the container refuses to start otherwise. A name with no
matching `.rules` file is refused too.

Start from a copy of `default.rules` (`docker run --rm lotuswebagency/php:8.5-fpm
cat /usr/local/etc/php/snuffleupagus/default.rules`) rather than an empty file:
a custom file replaces the baked ruleset instead of adding to it.

**Every setuid/setgid bit the runtime image inherited from the base image is
stripped** at build time (`find / -perm /6000 -exec chmod a-s`).

**Read-only rootfs** is a supported deployment shape — see
[Read-only root filesystem](#read-only-root-filesystem) above.

**The PrestaShop `chmod(0)` cache-bug shim** — PrestaShop's cache
regeneration calls `chmod($file, 0000)` and then rewrites the file; if the
rewrite fails or races, the file is stuck at mode `0000` and every request
after that 500s (PS issues #10998, #13050, #30786, #37666, reported since PS
1.7.4). `/usr/local/lib/php-chmod-sanitize.so`, an `LD_PRELOAD` shim built
with the same hardening flags as everything else in the image, promotes a
`chmod`/`fchmod`/`fchmodat` call of mode `0` to `0644` (files) / `0755`
(directories); every other mode passes through untouched. Off by default —
`PHP_CHMOD_SHIM=true` turns it on.

## Measured performance

The setup: nginx → FastCGI → FPM with `pm=static` and 8 workers, FPM limited
to 2 CPU cores, MariaDB, nginx and the load generator on their own cores,
opcache on, JIT off, `opcache.validate_timestamps=0`. [k6](https://k6.io/)
measures time to first byte against a PrestaShop shop, every response checked
for status 200 and the expected page. Each run is 5 rounds with the image order
rotated. "Stock" is `dementev/php-fpm-with-ext`, the predecessor image, on the
same PHP minor version. Absolute numbers depend on the host; the deltas are the
point. Each figure is the median of the per-round deltas, given for two
independent runs.

**PHP 8.5** — clang 19, PGO + ThinLTO, TAILCALL VM — vs. stock 8.5, on
PrestaShop 9.1.5:

| Metric | Run 1 | Run 2 |
|---|---|---|
| Max requests/sec | +11% | +10% |
| TTFB p50 at saturation | −9% | −9% |
| TTFB p50 at a fixed rate (70% of stock's max) | −12% | −9% |
| TTFB p95 at the fixed rate | −16% | −16% |

**PHP 8.4** — GCC 16.2, PGO, no LTO, HYBRID VM — vs. stock 8.4, on
PrestaShop 8.2.7:

| Metric | Run 1 | Run 2 |
|---|---|---|
| Max requests/sec | +5.7% | +5.2% |
| TTFB p50 at saturation | −5.4% | −4.7% |
| TTFB p50 at a fixed rate | −7.9% | −7.2% |
| TTFB p95 at the fixed rate | −9.0% | −8.2% |

The same comparisons were also run with clang 19 against the latest LLVM
(clang 23.1.2) on both versions. Clang 23 was within noise of clang 19 on 8.5,
and on 8.4 neither clang came close to GCC 16.2, because clang can only build
PHP's slower CALL VM there. That is why 8.5 stays on Debian's clang and
7.0–8.4 use GCC.

## Migrating from `php-fpm-with-ext`

- **Config path**: `/usr/local/etc/php/conf.d/10-php.ini` here, not `01-php.ini` — your own drop-in still just needs to sort after it (`99-*.ini`).
- **Extensions**: turned on with `PHP_EXT_ENABLE` at runtime instead of being baked per-tag; check the [extensions table](#extensions) above against what your app actually loads.
- **`disable_functions`**: `proc_open` was already exempt on the predecessor and still is here; `PHP_DISABLE_FUNCTIONS` now *adds to* the baked list instead of you having to restate it in a custom ini.
- **JIT**: on by default here (`opcache.jit=tracing`), off on the predecessor. Set `PHP_OPCACHE_JIT=off` if your app hasn't been profiled against it.
- **Healthcheck**: single-pool only (`PHP_FPM_LISTEN`/`ping.path=/fpm-ping`) — the predecessor's `FPM_HEALTH_PORTS` multi-pool support has no equivalent here.
- **Tags**: every PHP version now ships every flavor (the predecessor restricted `cli`/`cli-builder` to a handful of versions); `{version}-{flavor}` is unchanged, and `latest`/`{version}` now exist for the default version's `fpm` image (the predecessor shipped no `latest` at all, deliberately).
- **`LD_PRELOAD`**: the chmod shim is now gated by `PHP_CHMOD_SHIM=true` rather than setting `LD_PRELOAD` yourself.

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

Straight from [php.net's own supported-versions page](https://www.php.net/supported-versions.php)
and [EOL page](https://www.php.net/eol.php), not this project's opinion of
it. `eol_date` is upstream's final security-support-end date for that
version — already past for `end-of-life` versions, upcoming for `security`
and `active` ones. Every published image carries `com.lotuswebagency.support`
and `com.lotuswebagency.eol-date` labels with these exact values, and an
end-of-life image's `org.opencontainers.image.description` states the same
fact so it surfaces in a registry UI, not just in a label you have to know
to look for.

An end-of-life tag is still published and still rebuilt weekly for base-image
and package security updates — the PHP interpreter itself just receives no
further upstream fixes. See [SUPPORT.md](SUPPORT.md) for what that does and
doesn't mean in practice.

## Verifying images

Every published digest carries an SBOM, max-mode SLSA provenance, a
keyless Cosign signature bound to this repository's GitHub Actions identity
and signed test results, plus OpenVEX statements where an accepted finding
applies:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

Inspect the SBOM/provenance attestations directly:

```sh
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --format '{{ json .SBOM }}'
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --format '{{ json .Provenance }}'
```

Two more keyless attestations, from the same workflow identity, sit on the
platform images and on the multi-arch tag: signed test results on every one of
them, and OpenVEX where an accepted finding applies. The test-result one is
attached only after the smoke tests and the Trivy gate passed against the pushed
digest, and records the digest, PHP version, flavor, uarch, inputs hash, git
commit, workflow run URL, and per architecture the smoke verdict with every check
that passed and the Trivy verdict (taken from the Trivy step's own outcome, with
the scanner version and database date when the runner could read them). The
OpenVEX one carries the findings we accepted instead of fixing, each with its
reason and a re-review date (the source is [`vex/php.openvex.json`](vex/php.openvex.json)). Only an
image a statement applies to has one: today that is `cli-builder`, whose bundled
npm ships a `brace-expansion` and an `undici` with no fixed release yet.

```sh
cosign verify-attestation --type openvex \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-cli-builder | jq -r .payload | head -n1 | base64 -d | jq .predicate

cosign verify-attestation --type https://github.com/LotusWebAgency/php/attestation/test-result/v1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm | jq -r .payload | head -n1 | base64 -d | jq .predicate
```

`cosign verify-attestation` prints one line per attestation on the digest, and a
re-run of the release adds another rather than replacing the first, which is why
the commands above take `head -n1`. On a tag it checks the attestation on the
manifest list, which covers both architectures. To check one platform's own attestation,
resolve its digest first and verify `lotuswebagency/php@sha256:...` instead:

```sh
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --raw \
  | jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest'
```

Trivy can in principle apply the VEX document too
(`trivy image --vex oci lotuswebagency/php:8.5-cli-builder`); that is expected to
work against these attestations and will be verified after the first release.
Trivy only suppresses `not_affected` and `fixed` statements, and ours are
`affected` (accepted, no upstream fix, not claimed unreachable), so the findings
still show. The CI gate honors them through a `.trivyignore` generated from the
same file, which expires on the same date.

A pull request or a push to `develop` builds and tests without publishing to Docker Hub; a Trivy gate fails the
build on any fixable CRITICAL or HIGH finding before anything can reach a
registry (accepted risks are recorded with a reason and a re-review date in
[`vex/php.openvex.json`](vex/php.openvex.json); `.trivyignore` is generated from it). Trivy scans the Debian package layer -- it can't see the libraries
built from source and vendored under `/opt`: ImageMagick and net-snmp in every
build, plus the vendored OpenSSL and ICU (static) and curl (7.0–7.2) of the
7.0–8.0 builds. Those are tracked through `deps/versions.lock`'s pins instead. See
[SECURITY.md](SECURITY.md) for the reporting channel and what's automated.

## Branches and releases

Work lands on `develop` through pull requests. A pull request (to `develop` or
`main`) builds, tests and Trivy-gates a representative subset on amd64. A push
to `develop` builds every image natively on amd64 and arm64 and runs the smoke
tests, the extension end-to-end test and the Trivy gate on each, but never
publishes to Docker Hub. A pull request from `develop` to `main` is the release:
merging it builds, tests, publishes and signs every image. The weekly rebuild
runs on `main` only, to pick up base-image and package updates.

### Develop images in GHCR

Every image of a `develop` push that passed all of those tests is also pushed to
GitHub Container Registry, so it can be pulled and tested further before a release:

```
ghcr.io/lotuswebagency/php/dev:<tag>            # floating: the latest develop run in which every image passed
ghcr.io/lotuswebagency/php/dev:<tag>-<sha>      # multi-arch list for one commit (first 12 characters of the SHA)
ghcr.io/lotuswebagency/php/dev:<tag>-<sha>-<arch>   # single-arch image, amd64 or arm64
```

`<tag>` is the tag the release image carries on Docker Hub (`8.5-fpm`,
`8.4-cli-builder-v3`, `8.5-ext-builder`). Who can pull is whatever the package
settings of `php/dev` say (GHCR packages are private unless changed); for a
private package, `docker login ghcr.io` with a token that has `read:packages`.
These are unpublished test builds -- unsigned, without SBOM or provenance
attestations, not for production. Versions older than 14 days are deleted daily
(`dev-prune.yml`), except the commits the floating tags point at and the newest
one. The floating tags are only moved by a run whose commit is still the head of
`develop`, and only when every image of that run passed.

For the prune to delete anything, the `php` repository needs the Admin role on
the `php/dev` package (package settings, Manage Actions access); without it the
daily run is expected to fail on its deletions.

## Building locally

Every PHP build mounts its version's PGO training corpus (see
[Why build from source](#why-build-from-source) above), so a corpus image has
to exist before any real build does:

```sh
./tests/preflight.sh          # everything checkable without building: matrix
                               # drift, PGO-tier config, shellcheck, unit tests

# from a daemon with no lotuswebagency/php* images yet, build each corpus
# tier's floor cli-builder first (bootstrap targets, docker-bake.hcl):
for v in 7.0 7.1 7.2 8.1 8.2; do
  docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl "php-${v/./_}-cli-builder" \
    --set '*.platform=linux/amd64' --load
done
./tests/build-corpus.sh       # build the 5 PGO corpus tiers from those images

./tests/build-all.sh          # every fpm target, resumable, --only/--flavor/
                               # --platform/--dry-run to narrow it
./tests/smoke.sh lotuswebagency/php:8.5-fpm 8.5 fpm   # one already-built image
./tests/test-ext-builder.sh 8.5   # ext-builder end to end; needs that version's
                                   # ext-builder, fpm and cli images built
```

`tests/smoke.sh` fails an image whose `com.lotuswebagency.inputs-hash` label
doesn't match the working tree's current hash — a green gate on a stale
image proves nothing. `tests/build-all.sh` feeds that label automatically;
a manual `docker buildx bake` needs `INPUTS_HASH="$(./scripts/inputs-hash.sh)"`
set first.

### Testing develop images locally

Every image a `develop` run tests is also pushed to the private GHCR package
`ghcr.io/lotuswebagency/php/dev` as `<tag>-<first 12 of the sha>`, so the tests
CI doesn't run (the Laravel/WordPress/PrestaShop suites in `tests/apps/`, the
`-v3` instruction-set check, the corpus-tier replay and the benchmark) can run
against exactly those images instead of a local rebuild of all 50 targets; the
smoke suite and the ext-builder end to end, which CI does run, can be repeated
on them the same way. Log in once, with a token that can read packages:

```sh
gh auth refresh -s read:packages
gh auth token | docker login ghcr.io -u <github-user> --password-stdin

tests/extended.sh pull && tests/extended.sh all     # HEAD's images, this daemon's arch
tests/extended.sh pull --only 8.4,8.5 --flavor fpm,cli && tests/extended.sh apps --only 8.4,8.5 --flavor fpm,cli
tests/extended.sh pull --latest                     # the last fully green develop run instead
```

`pull` retags what it fetched to the `lotuswebagency/php:<tag>` names the
other scripts expect and prints every tag it replaces. The other subcommands
(`uarch`, `ext-builder`, `corpus-tiers`, `apps`, `smoke`, `bench`) don't
remember what was pulled, so repeat `--only`/`--flavor`; one that finds an
image absent says `MISSING`, and one from another tree says `STALE`. `all` runs
`uarch`, `ext-builder`, `corpus-tiers` and `apps` (not `smoke`, not `bench`:
those are subcommands of their own) even after a failure and ends with a table.
A step whose script passed without running its main check (the `-v3`
instruction-mix check on arm64, the corpus-tier control when no image below the
floor is present) is `PARTIAL`, and a run in which every row is `SKIP` fails: it
tested nothing. After a retag the `dev:` tag is removed again, the canonical
`lotuswebagency/php:<tag>` keeps the layers. `tests/extended.sh --help` has the
rest.

To spread a run over several machines or sessions, give `pull` and every test
the same `--only`/`--flavor` selection per shard:

```sh
tests/extended.sh pull --only 8.0,8.1 && tests/extended.sh all --skip-pull --only 8.0,8.1
tests/extended.sh pull --only 8.2,8.3 && tests/extended.sh all --skip-pull --only 8.2,8.3
```

(`pull --no-corpus` is for a shard that runs neither `corpus-tiers` nor
`smoke`, e.g. `uarch`, `ext-builder` and `apps` one by one.)

The images have to be the tree you are standing in. Each carries the
`inputs-hash` of the commit it was built from, and `tests/smoke.sh` and
`tests/test-pgo.sh` refuse an image whose hash differs from the working tree's
(that check has no override here). `pull` therefore refuses when the hashes
differ, and prints the command that fixes it: check the commit out in its own
worktree and run `tests/extended.sh` from there. Uncommitted changes in a
hashed path change the hash too (`git status`), and when HEAD has no images
because its develop run was cancelled, `pull --latest` takes the last green
run, which carries the same hash when only unhashed files changed since. If
the very first image cannot be pulled (not in the registry, or no access) `pull`
stops there instead of trying the other fifty.

```sh
git worktree add ../php-<sha12> <sha>
```

Only the architecture of your daemon can be tested locally. arm64 under QEMU
crashes opcache, so the arm64 images are exercised by GitHub's arm64 runners
and `pull` refuses `--platform linux/arm64` on an amd64 daemon. The app
fixtures can come from a registry too, see
[tests/apps/README.md](tests/apps/README.md#fixtures-from-a-registry).

#### The extended tests in CI

`.github/workflows/extended.yml` runs the same `tests/extended.sh` suites
(`-v3` check, ext-builder, corpus-tier replay, the app suites, optionally the
benchmark) on native amd64 and arm64 runners, against the develop images in
GHCR. It is its own workflow: it never gates develop and a newer develop push
does not cancel it. Per PHP version and architecture one job pulls that
version's images and runs `uarch`, `ext-builder` and `apps`; one job per
architecture runs `corpus-tiers`; a fixtures job per architecture first
publishes any missing or stale app fixture to
`ghcr.io/lotuswebagency/php/apptest`; a summary job collects every
`results.tsv` and fails when a required job did. A `plan` job fixes one image
commit for all of them.

```sh
gh workflow run extended.yml --ref develop                    # the floating images (last green develop run), tests from the ref
gh workflow run extended.yml --ref develop -f sha=<sha>       # that commit's images; the ref's tests if its inputs-hash matches
gh workflow run extended.yml --ref develop -f only=8.4,8.5 -f flavor=fpm,cli -f apps=false -f bench=true
```

Without `sha` the run fails up front when the ref's `inputs-hash` differs from
the floating images'; then dispatch with `sha=` the commit it names. With a
`sha` whose `inputs-hash` differs from the ref's, every job runs that commit's
own tree, so this only works for a commit that already contains the extended
workflow's scripts (the commit that added `extended.yml`, or a later one); for
an older commit `plan` fails up front saying so. After a
successful `ci` run on a develop push the workflow also starts by itself, but
GitHub only fires `workflow_run` (and only accepts `workflow_dispatch`) for
workflow files on the default branch, so until this one is on `main` neither
works. Push the commit whose images should be tested to the `extended-run`
branch instead, which starts the workflow from the pushed commit's own copy of
the file and tests that commit's images with its own tests:

```sh
git push origin <sha>:refs/heads/extended-run
# when the run is done, so the next push is a new branch and not a rejected update:
git push origin :extended-run
```

If develop CI pushed no images for that commit (one that only changed `tests/`
or `ci/`, which are outside the `inputs-hash`, is never built), the run tests
the last green develop images instead, provided their `inputs-hash` equals the
pushed tree's; the plan log and job summary say which path was taken. With a
differing hash it fails up front.

No force push: delete the branch after each run and push a fresh one next time.
The branch must not be protected, and `ci` does not run on it. Logs and
`results.tsv` files are kept as artifacts for five days.

Automatic runs (after `ci`, or a push to `extended-run`) share one concurrency
group: a run in flight is never cancelled and only the newest pending one waits
behind it. A selection without the `fpm`, `cli` or `cli-builder` flavor builds
no fixtures and runs no app suites. Every job starts with `ci/free-disk.sh`
(fails below 20 GB free, `FREE_DISK_MIN_GB`) and ends by logging `df` and
`docker system df`.

The app fixtures are images committed locally, labelled
`org.opencontainers.image.source=https://github.com/LotusWebAgency/php`, which
is what links the `php/apptest` GHCR package to this repository and lets the
workflow's `GITHUB_TOKEN` push and pull it. If a package of that name already
existed before it was linked, give this repository access to it (package
settings, "Manage Actions access", role Write) or the push is denied.

## Related images

One family, built by the same pipeline, meant to run together — a proxy in
front, an app runtime, a database, and a way into it.

| Image | What it does |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) — [source](https://github.com/vdementev/angie-docker) | Public-facing reverse proxy and TLS terminator — Angie, the nginx fork, with brotli, zstd and cache-purge |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) — [source](https://github.com/vdementev/nginx-docker) | Static sites and SPAs behind that proxy — brotli/zstd siblings, Prometheus stub_status |
| **[`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php)** — this image — [source](https://github.com/LotusWebAgency/php) | PHP 7.0 → 8.5 compiled from source with PGO and per-era compiler tuning, hardened |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) — [source](https://github.com/vdementev/mysql-percona-docker) | Percona Server for MySQL 8.4 LTS, XtraBackup built in, no root inside |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) — [source](https://github.com/vdementev/adminer-docker) | Adminer 6 with every driver it supports, for reaching any of the above |

## Maintainer

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). These images are not a side
project — they are the base layer under the client and product systems we run,
which is why they are gated, tested and signed rather than pushed by hand.

Issues and pull requests:
[github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Need this kind of infrastructure built or maintained for your own stack?
[lotuswebagency.com](https://lotuswebagency.com).

Packaging in this repository is MIT licensed — see [LICENSE](LICENSE). PHP and
the bundled extensions keep their own upstream licenses.
