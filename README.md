# php

PHP 7.0 through 8.5, compiled from source on Wolfi (`cgr.dev/chainguard/wolfi-base`, pinned by
digest) with profile-guided optimization (PGO) trained on real PrestaShop, WordPress, Laravel,
Symfony and Drupal applications. Binaries are hardened at the ELF level, Snuffleupagus virtual
patching is available, and a read-only root filesystem is supported. A complete hardened setup is in
[Hardened deployment](#hardened-deployment); the [Image contract](#image-contract) lists the facts a
deployment script or agent needs.

Docker Hub: [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php).
Source: [github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Coming from `dementev/php-fpm-with-ext`? See [Migrating](#migrating-from-php-fpm-with-ext).
Coming from a Debian- or Alpine-based PHP image? See [Moving from a Debian or Alpine base](#moving-from-a-debian-or-alpine-base).

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    volumes:
      - ./:/app
```

## Tags

All 11 PHP versions ship all four flavors for `linux/amd64` and `linux/arm64`: 50 images, 44 baseline plus 6 `-v3`. `Support` and
`EOL date` are upstream's values from [php.net](https://www.php.net/supported-versions.php). They
come from `matrix.json` and are carried on every image as the `com.lotuswebagency.support` and
`com.lotuswebagency.eol-date` labels.

| PHP | Release | Compiler | `-v3` | Support | EOL date |
|---|---|---|---|---|---|
| `7.0` | 7.0.33 | gcc | no | end-of-life | 2019-01-10 |
| `7.1` | 7.1.33 | gcc | no | end-of-life | 2019-12-01 |
| `7.2` | 7.2.34 | gcc | no | end-of-life | 2020-11-30 |
| `7.3` | 7.3.33 | gcc | no | end-of-life | 2021-12-06 |
| `7.4` | 7.4.33 | gcc | no | end-of-life | 2022-11-28 |
| `8.0` | 8.0.30 | gcc | no | end-of-life | 2023-11-26 |
| `8.1` | 8.1.34 | gcc | no | end-of-life | 2025-12-31 |
| `8.2` | 8.2.35 | gcc | no | security | 2026-12-31 |
| `8.3` | 8.3.36 | gcc | no | security | 2027-12-31 |
| `8.4` | 8.4.27 | gcc | yes | active | 2028-12-31 |
| `8.5` | 8.5.12 | clang | yes | active | 2029-12-31 |

End-of-life tags are still published and rebuilt weekly for base-image and package updates. The PHP
interpreter in them gets no upstream fixes. See [SUPPORT.md](SUPPORT.md) and
[Older PHP versions](#older-php-versions).

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every published image. |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | Built for `x86-64-v3` / `armv9-a` instead of the `x86-64-v2` / `armv8-a` baseline. 8.4 and 8.5 only, not for `ext-builder`. |
| `{version}`, `latest` | `8.5`, `latest` | The default version's `fpm` image (`default_version` in `matrix.json`, currently 8.5). |
| `{release}-{flavor}[-v3]` | `8.5.12-fpm` | Full patch version. Read from the built image (`PHP_VERSION`) after tests and the Trivy gate, so a tag cannot name a version the image does not contain. |

`-v3` images need a newer CPU. On amd64 older than Haswell/Excavator they refuse to start: a startup
check in the `php` and `php-fpm` binaries exits 127 with
`this build requires an x86-64-v3 CPU`. arm64 has no such check, so an unsupported core gets SIGILL. `armv9-a` code needs Neoverse N2/V2-class cores (Graviton4, Google Axion, Azure Cobalt
100, NVIDIA Grace). It does not run on Graviton2/3 or Ampere Altra. Apple M4-M6 do not provide SVE2
in normal mode, so `-v3` also dies with SIGILL in Docker Desktop and OrbStack. Use the baseline tag
on a Mac.

The amd64 baseline is `x86-64-v2` (SSE4.2 and POPCNT; Intel Nehalem and newer, AMD Bulldozer and
newer), not plain `x86-64`, because Wolfi's packages are built for it: its glibc, busybox and curl
carry an `x86-64-v2` ISA requirement, so a CPU below that fails at the first `exec`. Both baselines
use generic tuning (`-mtune=generic`), so the code is not tied to one core. amd64 `-v3` also tunes
generic; arm64 `-v3` tunes for `neoverse-v2`, under both compilers. Only the amd64 `-v3` tags check
the CPU at startup.

The vendored ImageMagick and the heif stack (libheif, libde265, dav1d) are built for the
baseline in every image, `-v3` included. Their code runs on any CPU the baseline tag supports.

A tag names the PHP minor, so `8.4-fpm` moves with each 8.4 patch release. Pin the digest for
reproducible builds: `FROM lotuswebagency/php:8.4-fpm@sha256:...`.

## Older PHP versions

These caveats apply to the end-of-life tags. PHP 8.2 and later have none of them.

- **No security fixes.** PHP 8.1 and below get no upstream fixes. The weekly rebuild updates the
  Wolfi packages, not the interpreter's source. See [SUPPORT.md](SUPPORT.md).
- **Vendored libraries on 7.0 to 8.0.** OpenSSL 1.1.1w, ICU (67.1 on 7.0-7.3, 70.1 on 7.4-8.0),
  libxml2 2.9.14 and libxslt 1.1.35 are linked statically, and curl too on 7.0-7.2. OpenSSL 1.1.1 is
  end-of-life upstream. PHP's own TLS (the openssl extension, streams, mysqlnd) uses that copy and
  reads `/etc/ssl/openssl-1.1/openssl.cnf`, not `/etc/ssl/openssl.cnf`. Trivy cannot see these
  libraries, so they are tracked by hand.
- **MySQL through mysqli and PDO.** PHP's driver (mysqlnd) is older than MySQL 8's defaults:

  | PHP | `caching_sha2_password` accounts | `mysql_native_password` accounts on stock MySQL 8 / Percona 8 | MySQL 9 | TLS to MySQL 8.4 / MariaDB 11 |
  |---|---|---|---|---|
  | 7.0 | no | no | no | no |
  | 7.1 | no | yes | no | no |
  | 7.2, 7.3 | no | yes | no | yes |
  | 7.4, 8.0 | yes | yes | yes | yes |

  - PHP 7.0 refuses any server whose default plugin is `caching_sha2_password`, whatever plugin the
    account uses. On MySQL or Percona 8.4, start the server with `--mysql-native-password=ON
    --authentication-policy=mysql_native_password` and create the account `IDENTIFIED WITH
    mysql_native_password`. On 8.0 to 8.3 the server option is
    `--default-authentication-plugin=mysql_native_password`.
  - PHP 7.1 to 7.3 need a `mysql_native_password` account. MySQL 8.4 disables that plugin unless
    the server runs with `--mysql-native-password=ON`.
  - MySQL 9 removed `mysql_native_password`, so PHP 7.0 to 7.3 cannot log in to it at all.
  - PHP 7.0 and 7.1 negotiate TLS 1.0 only, which MySQL 8.4 and MariaDB 11 refuse. Connect without
    TLS, over a private network.
  - `sha256_password` accounts fail over TLS up to PHP 8.0. They work without TLS, through the RSA
    key exchange.
  - MySQL 5.7 and MariaDB work from every version.

  The MariaDB command-line tools are the same in every tag and have none of these limits.
- **Extensions.** `pcov` needs 7.1+, `sodium` and `snuffleupagus` 7.2+, `ffi` 7.4+, `mongodb`
  8.1+, `protobuf` and `swoole` 8.2+. `mcrypt` and `xmlrpc` ship on 7.x only.
- **JIT.** PHP 8.1+ has it on both architectures, 8.0 on amd64 only. Below 8.0 there is no JIT, so
  `PHP_OPCACHE_JIT` and `PHP_OPCACHE_JIT_BUFFER` have no effect.
- **Locale.** Under a non-UTF-8 `LC_CTYPE`, PHP 7.x's `basename()` and `pathinfo()` drop multibyte
  characters, and `ZipArchive::extractTo()` mangles such names. The images set `LANG=C.UTF-8`; do
  not override `LANG` or `LC_ALL` with `C` or `POSIX` on 7.x.
- **CPU.** `-v3` tags exist for 8.4 and 8.5 only.

## Flavors

| Flavor | Contents |
|---|---|
| `fpm` | PHP-FPM on `:9000` for a FastCGI-speaking reverse proxy. `STOPSIGNAL SIGQUIT` and a FastCGI `HEALTHCHECK` (`php-fpm-healthcheck`) that needs no web server. |
| `cli` | `php -a` by default. Scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, Node.js 26 with npm 12.2.1 and corepack, semantic-release and [Composer](https://getcomposer.org/) (installed with signature verification). No compiler. For build stages. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, glibc and Linux headers and the PHP headers with `phpize` / `php-config`. Runs as root, no Composer, no Node.js. Wolfi's openssf compiler wrappers stay on, so extensions built here get Wolfi's hardening flags. They also take Wolfi's default `-march`/`-mtune`, not the generic tuning the PHP build uses. For build stages. |

All images use `tini` as PID 1. All but `ext-builder` run as `www-data` (UID and GID 33).

### Base image and tools

The base is Wolfi, a glibc distribution. `/etc/apk/repositories` points at `packages.wolfi.dev/os`
and nothing else. Every flavor has `apk`, bash, curl, nano, less, procps, tzdata, ca-certificates,
zip, unzip, zstd, xz, bzip2, the PostgreSQL 18 client (`psql`, `pg_dump`, `pg_restore`) and the
MariaDB 13.1 client. The MariaDB client is `mariadb`. `mysql`, `mysqldump`, `mysqladmin` and
`mysqlcheck` are one-line wrapper scripts that `exec` `mariadb`, `mariadb-dump`, `mariadb-admin` and
`mariadb-check`. The last three are copied from the MariaDB server package in a build stage, so the
server and its perl dependency stay out of the image; they are not in apk's database.

The MariaDB tools log in to MySQL 5.7 and later, Percona Server and MariaDB with any of their
password plugins: `caching_sha2_password` (the MySQL 8 default), `sha256_password`,
`mysql_native_password`, `client_ed25519` and `parsec`. The plugins come from Wolfi's
`mariadb-connector-c`. `/etc/my.cnf` sets `ssl-verify-server-cert = 0` for them, so they use TLS when
the server offers it and plaintext when it does not, like MySQL's `--ssl-mode=PREFERRED`. Pass
`--ssl-verify-server-cert` to require a verified certificate. OpenSSL 4 has no DHE key exchange, and
a MySQL 5.7 built against OpenSSL 1.0.x (the official `mysql:5.7` image) offers nothing else, so TLS
to it fails with a handshake error: connect with `--skip-ssl`.

`php-fcgi` is a small FastCGI client, written in PHP, that sends one request to a pool and prints the
body. The fpm healthcheck uses it, since Wolfi has no `cgi-fcgi`. Usage is in the header of
[`rootfs/usr/local/bin/php-fcgi`](rootfs/usr/local/bin/php-fcgi).

There is no apt, dpkg, `ldd`, `getent`, `useradd` or other shadow tool. `fpm` and `cli` have no perl;
`cli-builder` and `ext-builder` do, because git and autoconf need it. Setuid and setgid bits are
stripped in every flavor.

## Quick start

FPM: point your FastCGI proxy at `php:9000`.

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

CLI, one-shot:

```sh
docker run --rm -v "$PWD:/app" -w /app lotuswebagency/php:8.5-cli php artisan queue:work --once
```

Multi-stage build:

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

`docker-php-entrypoint` turns environment variables into ini files and FPM pool settings once, then
`exec`s the command. A variable that is set but empty, or contains a newline, stops the container
with a message naming it. Unset a variable to get the image default.

| Variable | Default | Sets |
|---|---|---|
| `PHP_MEMORY_LIMIT` | fpm `256M`, cli and ext-builder `512M`, cli-builder `-1` | `memory_limit` |
| `PHP_MAX_EXECUTION_TIME` | fpm `300`, others `0` | `max_execution_time` |
| `PHP_MAX_INPUT_TIME` | `120` | `max_input_time` |
| `PHP_MAX_INPUT_VARS` | `10000` | `max_input_vars` |
| `PHP_UPLOAD_MAX_FILESIZE` | `128M` | `upload_max_filesize` |
| `PHP_POST_MAX_SIZE` | `128M` | `post_max_size` |
| `PHP_TIMEZONE` | unset | `date.timezone` |
| `PHP_ERROR_REPORTING` | `E_ALL & ~E_DEPRECATED` | `error_reporting` |
| `PHP_DISPLAY_ERRORS` | `Off` | `display_errors`. Errors go to stderr regardless. |
| `PHP_DISABLE_FUNCTIONS` | fpm: `passthru, shell_exec, exec, system, show_source, dl, popen, pcntl_exec` (the variable's baked value). cli, ext-builder: the variable is unset; the same list is baked into `10-php.ini`. cli-builder: none | Names to disable in addition to the baked list. Never replaces it. |
| `PHP_OPCACHE_ENABLE` | `1` | `opcache.enable` |
| `PHP_OPCACHE_MEMORY` | one eighth of the container memory limit, clamped to 64-512 MB | `opcache.memory_consumption`. A bare number is MB; `K`/`M`/`G` suffixes work. |
| `PHP_OPCACHE_VALIDATE_TIMESTAMPS` | `1` | `opcache.validate_timestamps`. Set `0` when deploys replace the whole tree. |
| `PHP_OPCACHE_REVALIDATE_FREQ` | `2` | `opcache.revalidate_freq` |
| `PHP_OPCACHE_PRELOAD` | unset | `opcache.preload` |
| `PHP_OPCACHE_JIT`, `PHP_OPCACHE_JIT_BUFFER` | `tracing`, `64M` | `opcache.jit`, `opcache.jit_buffer_size`. PHP 8.1+, and 8.0 on amd64. 8.0 on arm64 has no JIT: its opcache builds one for x86 only. |
| `PHP_EXT_ENABLE` | unset | Comma-separated shared extensions to load. See [Extensions](#extensions). |
| `PHP_SNUFFLEUPAGUS` | unset | Ruleset name to load. See [Hardening](#hardening). |
| `PHP_CHMOD_SHIM` | `0` | `1`, `true`, `yes` or `on` preloads the [chmod shim](#hardening). `0`, `false`, `no`, `off` disable it. Anything else is refused. |
| `PHP_INI_SCAN_DIR` | image default | Standard PHP variable. The entrypoint adds the baked `conf.d` and its generated directory back in. Setting it to the empty string disables ini scanning, so the entrypoint refuses to start when `PHP_DISABLE_FUNCTIONS` is also set, and always on fpm, which bakes `PHP_DISABLE_FUNCTIONS`. |

`fpm` only:

| Variable | Default | Sets |
|---|---|---|
| `PHP_FPM_PM` | `dynamic` | `pm` |
| `PHP_FPM_MAX_CHILDREN` | autotuned | `pm.max_children` |
| `PHP_FPM_START_SERVERS`, `PHP_FPM_MIN_SPARE`, `PHP_FPM_MAX_SPARE` | derived | `pm.start_servers`, `pm.min_spare_servers`, `pm.max_spare_servers` |
| `PHP_FPM_WORKER_MEMORY` | `64` | Memory assumed per worker when autotuning (MB, or `K`/`M`/`G` suffix). |
| `PHP_FPM_MAX_REQUESTS` | `1000` | `pm.max_requests` |
| `PHP_FPM_LISTEN` | `0.0.0.0:9000` | `listen` |
| `PHP_FPM_STATUS_PATH` | `/fpm-status` | `pm.status_path` |
| `PHP_FPM_ACCESS_LOG` | `/proc/self/fd/2` | `access.log` |
| `PHP_FPM_SLOWLOG_TIMEOUT` | `10s` | `request_slowlog_timeout` |

The ping endpoint is fixed at `/fpm-ping` (response `pong`) and is what the healthcheck uses.

**Pool autotuning.** The entrypoint reads the container memory limit from cgroup. Without a limit it
assumes 512 MB and logs that. It reserves opcache memory plus 64 MB and divides 80% of the rest by
the worker memory to get `max_children` (minimum 4). `start_servers` is a quarter of that (minimum
2), `min_spare_servers` equals it, and `max_spare_servers` is half (minimum 4). A value you set is
used exactly. Derived values adjust to stay consistent with it and are capped at `max_children`.
Do not set `PHP_FPM_*_EFFECTIVE`: those are the entrypoint's computed output, and a value other than
the baked default is refused with a message naming the variable to use.

**`PHP_DISABLE_FUNCTIONS`.** Names are lowercase, separated by commas or spaces, and must resolve to
a real function. After loading extensions and rulesets, the entrypoint asks PHP (per FPM pool, or for
the command about to run) whether each name is actually disabled, and refuses to start if not.
`proc_open` is not on the baked list because Composer and `symfony/process` need it.

`docker exec <container> php ...` does not see the env-driven ini. Use
`docker exec <container> docker-php-entrypoint php ...` to apply it.

### Read-only root filesystem

`fpm`, `cli` and `cli-builder` run with `--read-only` and one writable mount, `/tmp`:

```yaml
services:
  php:
    image: lotuswebagency/php:8.5-fpm
    read_only: true
    tmpfs:
      - /tmp:size=256m
```

`/tmp` is the only path written at runtime (`tests/test-readonly.sh` checks this with `docker diff`
after a full workload). It holds sessions and upload temp files (size the tmpfs for your largest upload
times concurrent uploads, plus sessions; a tmpfs counts against the container memory limit), the
env-driven ini, `sys_get_temp_dir()` and `tempnam()` files, Xdebug output, and in `cli-builder` the
Composer, npm and corepack caches. When `conf.d` is not writable, the entrypoint writes the ini to a
private mode-0700 `mktemp` directory under `/tmp`, so all `PHP_*` variables apply as on a writable
rootfs. Directories left by exited containers are reaped on the next start.

`fpm` and `cli` work with Docker's default `noexec` on the tmpfs. `cli-builder` needs
`/tmp:exec,size=256m` because `npx` runs packages from `/tmp/npm/_npx`.

Without a writable `/tmp`, `PHP_EXT_ENABLE` and `PHP_SNUFFLEUPAGUS` refuse to start the container,
and the other `PHP_*` ini variables are ignored with a warning naming each one. Your application's
own writes (PrestaShop `var/cache`, Laravel `storage`, WordPress uploads) need their own volume. A
FastCGI unix socket needs a writable directory, so keep the TCP default for `PHP_FPM_LISTEN` or mount
one. In Kubernetes use `readOnlyRootFilesystem: true` with an `emptyDir` at `/tmp`; that mapping is
not covered by the tests.

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

The same with `docker run`:

```sh
docker run -d --name php \
  --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev,size=256m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  --pids-limit 256 --memory 1g \
  -e PHP_SNUFFLEUPAGUS=default -e PHP_OPCACHE_JIT=disable -e PHP_OPCACHE_VALIDATE_TIMESTAMPS=0 \
  -v storage:/app/storage \
  registry.example.com/myapp:1.0
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
  `PHP_EXT_ENABLE` refuse to start. See [Read-only root filesystem](#read-only-root-filesystem).
- **`cap_drop: [ALL]`.** Nothing in `fpm` or `cli` needs a capability. The FPM master already runs as
  `www-data`, so the log notes that the pool's `user` and `group` lines are ignored; that is expected.
  Keep `PHP_FPM_LISTEN` on a port above 1024.
- **`no-new-privileges`.** No setuid binary is left to gain privileges with; this closes the path for
  anything added later.
- **Snuffleupagus.** Pick the ruleset that matches the application, or start a custom one from
  `default` (see [Hardening](#hardening)). Rulesets are for serving: run Composer and other build
  steps in `cli-builder` without one. Snuffleupagus hooks the executor, so PHP turns the JIT off
  while it is loaded and logs a startup warning. `PHP_OPCACHE_JIT=disable` says so up front and
  removes the warning; `off` does not, because it keeps the JIT buffer.
- **`PHP_DISABLE_FUNCTIONS`.** Adds names to the baked list, for example `proc_open` when the
  application never starts processes. Laravel queues, Symfony Process and Composer need `proc_open`.
  The entrypoint refuses to start if a listed name does not end up disabled.
- **Limits.** `pids_limit` bounds runaway forks; the memory limit bounds the container and drives FPM
  and opcache autotuning (512 MB is assumed without one).
- **Network.** `fpm` speaks FastCGI on 9000 and should only be reachable by the web server. Never
  publish 9000 to the host.
- **Errors.** `PHP_DISPLAY_ERRORS` stays `Off` (the default); errors go to stderr.

Kubernetes, the same controls on the container (not covered by the tests):

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 33
  runAsGroup: 33
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
volumeMounts:
  - { name: tmp, mountPath: /tmp }
# pod spec: volumes: [{ name: tmp, emptyDir: { medium: Memory, sizeLimit: 256Mi } }]
```

## Extensions

73 extensions, defined in [`php/ext.json`](php/ext.json); 72 are built (`imap` is registered but not
built: Wolfi has no c-client library). The registry drives configure flags, the build and
the smoke test's assertions, and lists each extension's source, linkage, PHP range and purpose.

- **53 are compiled in** and need nothing to use: the usual core set plus `igbinary`, `redis`,
  `imagick`, `memcached`, `apcu` and `zstd`. `imagick` reads HEIC and AVIF (static libheif,
  libde265 and dav1d inside ImageMagick) but does not write them.
- **19 are shared modules**, built but not loaded. Load them with `PHP_EXT_ENABLE: "ldap,uuid"`:
  `amqp`, `brotli`, `bz2`, `event`, `ffi` (7.4+), `ldap`, `lz4`, `mcrypt` (7.x),
  `mongodb` (8.1+), `msgpack`, `pcov` (7.1+), `protobuf` (8.2+), `snuffleupagus` (7.2+),
  `swoole` (8.2+), `tidy`, `uuid`, `xdebug`, `xmlrpc` (7.x), `yaml`.

`php-ext-enable` refuses an unknown or unavailable name and lists what the image has. `xdebug` and
`snuffleupagus` load as Zend extensions automatically. `ffi` is shipped disabled because it bypasses
PHP-level sandboxing.

There is no `ssh2` extension. For SSH and SFTP from PHP use [phpseclib](https://phpseclib.com/),
which is pure PHP and is what Laravel's and Flysystem's SFTP adapters use. Code that calls
`ssh2_*` functions can compile the PECL extension in an `ext-builder` stage
([Adding your own extension](#adding-your-own-extension)).

### Adding your own extension

The images carry no `pecl`, `pear` or `docker-php-ext-install`. Compile in an `ext-builder` stage
and copy only the `.so`:

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
  PHP minor does not load in another.
- Install runtime libraries (`libmyext`, not `-dev`) in the final stage as root, then switch back
  to `www-data`.
- Package names are Wolfi's, not Debian's. `apk search` finds one by name, and
  `apk info -W /usr/lib/libfoo.so.1` names the package that owns a file. Wolfi names some library
  packages by version (`libicu78`). Headers for libraries the image already links come from the
  same index: on 8.1 and later PHP uses OpenSSL 4, so the header package is `openssl-4.0-dev`.
  `openssl-dev` is the OpenSSL 3 package and conflicts with it.
- `PHP_EXT_ENABLE=myext` works for any `myext.so` in the extension directory. For another
  `zend_extension`, put a `zend_extension=myext.so` file in `/usr/local/etc/php/conf.d/`.
- `ext-builder` has no `-v3` variant: an extension built against baseline headers loads in `-v3`
  runtimes too. `tests/test-ext-builder.sh` covers this flow with `tests/fixtures/ext-hello`.

## Hardening

`tests/assert-elf-hardening.sh` measures the produced binaries instead of trusting compiler flags:

- **PIE** (`ET_DYN`).
- **Full RELRO**: `GNU_RELRO` segment and `BIND_NOW`.
- **Non-executable stack**: `GNU_STACK` flags `RW`.
- **Stack protector** (`-fstack-protector-strong`): `__stack_chk_fail` is in the main binary's
  dynamic symbols.
- **`_FORTIFY_SOURCE=3`**: fortifiable libc calls resolve to `__*_chk`.
- **Control-flow protection**, checked on php-src's own functions (the vendored static libraries
  would otherwise hide a gap):
  - amd64 (`-fcf-protection=full`): at least half of the function entries start with an `endbr64`
    landing pad. The loader-enforced IBT/SHSTK property note is not claimed, because it is absent
    from these binaries.
  - arm64 (`-mbranch-protection=standard`): at least half of the entries start with `bti` or a
    `paciasp`/`pacibsp` instruction, so PAC and BTI are compiled in. On PHP 7.0-8.4 (gcc, linked with
    gold) BTI is not enforced at runtime: gold writes no `PT_GNU_PROPERTY` header, and glibc turns BTI
    on from that header.
- Every link uses `-z relro -z now -z noexecstack --as-needed --build-id=sha1`, plus
  `-z pack-relative-relocs` (packed `DT_RELR` relocations) where the linker supports it.
- Wolfi's compiler wrappers add their own hardening spec and bake in `-mtune=sapphirerapids` (arm64:
  `neoverse-v2`). The PHP build turns the hardening spec and clang's default config off, and
  `php/cflags.sh` passes every hardening and `-march`/`-mtune` flag explicitly, vendored libraries
  included. Besides the flags above, that set is `-ftrivial-auto-var-init=zero`,
  `-fno-delete-null-pointer-checks`, `-fno-strict-overflow` and `-fno-strict-aliasing` on both
  compilers, `-fzero-init-padding-bits=all` on gcc only (clang has no such option) and
  `-D_GLIBCXX_ASSERTIONS` for C++. It reaches php, PECL and shared extensions, the chmod shim and the
  vendored libraries. Snuffleupagus's build file forces `_FORTIFY_SOURCE=2`; a patch in
  `deps/patches/` removes that, so the module is built at level 3 like everything else.
- Every setuid and setgid bit inherited from the base image is stripped.
- Busybox's network applets (`ping`, `netstat`, `traceroute`, `arping`, `microcom` and the rest of
  the raw-socket and interface set) are removed; `curl` stays. A derived image that runs
  `apk add` gets the busybox links back and can prune them again.

**Snuffleupagus.** [Virtual patching](https://github.com/jvoisin/snuffleupagus) is compiled in but
not loaded by default. Four rulesets are baked into `/usr/local/etc/php/snuffleupagus/`: `default`,
`wordpress`, `prestashop` and `laravel`. Enable one with `PHP_SNUFFLEUPAGUS=prestashop`. Snuffleupagus is not available on PHP 7.0 and 7.1. Rulesets are
for serving; build and deploy (Composer included) with `cli-builder` and no ruleset. No ruleset enables
`readonly_exec`; the PrestaShop and Laravel ones disable it explicitly because both frameworks rewrite their own cache
files. `sp.xxe_protection`
is off in all of them: it does not carry into requests, and on PHP 7 it disables the application's own
`libxml_disable_entity_loader(true)`. libxml2 2.9 and later loads external entities only if the
application passes `LIBXML_NOENT` or `LIBXML_DTDLOAD`. On PHP 7, call
`libxml_disable_entity_loader(true)` yourself.

For your own rules, mount a file into the ruleset directory and select it by name:

```yaml
environment:
  PHP_SNUFFLEUPAGUS: my-site
volumes:
  - ./my-site.rules:/usr/local/etc/php/snuffleupagus/my-site.rules:ro
```

The name matches `^[a-z0-9][a-z0-9_-]*$` and is never a path. A name with no `.rules` file is
refused. A custom file replaces the baked ruleset instead of adding to it, so start from a copy:
`docker run --rm lotuswebagency/php:8.5-fpm cat /usr/local/etc/php/snuffleupagus/default.rules`.

**PrestaShop `chmod(0)` shim.** PrestaShop's cache regeneration calls `chmod($file, 0000)` and then
rewrites the file. If the rewrite fails or races, the file stays at mode `0000` and every later
request returns 500. `/usr/local/lib/php-chmod-sanitize.so` (source in `shim/`) is an `LD_PRELOAD`
shim that turns a `chmod`, `fchmod` or `fchmodat` with mode `0` into `0644` for files and `0755` for
directories. Other modes pass through. Enable it with `PHP_CHMOD_SHIM=true`.

## How it is built

- **Base image.** `cgr.dev/chainguard/wolfi-base`, pinned by digest in `matrix.json`. CI verifies
  that digest's Chainguard cosign signature before any job builds on it, and every image carries the
  `org.opencontainers.image.base.name` and `org.opencontainers.image.base.digest` labels. Packages
  come from `packages.wolfi.dev/os` only. The runtime layer runs `apk upgrade`, so a rebuild picks up
  Wolfi fixes published since the digest was pinned.
- **Compiler per PHP era** (`compiler` in `matrix.json`). PHP 7.0-8.4 build with GCC 16.2, PGO and no
  LTO, because GCC's LTO rejects the HYBRID VM's global register variables. PHP 8.5 builds with
  clang 19, PGO and ThinLTO, which gives the TAILCALL VM. Both come from Wolfi packages. `-std=gnu17`
  is pinned for every version, because GCC 15's `gnu23` default breaks K&R-style code in php-src and
  PECL sources.
- **Instruction set.** The amd64 baseline is `-march=x86-64-v2 -mtune=generic`, arm64 is
  `-march=armv8-a -mtune=generic`. `-v3` is `-march=x86-64-v3` on amd64 and `-march=armv9-a` on
  arm64, with a startup check on amd64 (see [Tags](#tags)). Flags: `php/cflags.sh`.
- **Dependencies by era.** PHP 8.1-8.5 link Wolfi's libraries, including its system OpenSSL 4, so one
  OpenSSL runs in the process: smoke fails an image that carries a `libssl` or `libcrypto` of major 1
  or 3. Every PHP 8.1-8.5 build carries a patch that widens the `SSL_CTX` options in `ext/openssl`
  to 64 bits, and 8.1 also needs one for OpenSSL 4's opaque `ASN1_STRING`. PHP 7.0-8.0 vendor, from
  `deps/versions.lock` and linked statically, OpenSSL 1.1.1w (with a private openssldir,
  `/etc/ssl/openssl-1.1`), ICU (67.1 on 7.0-7.3, 70.1 on 7.4-8.0), and libxml2 2.9.14 and libxslt
  1.1.35 from Debian trixie's source
  packages with Debian's security patches. No end-of-life `libssl.so` ships. PHP 7.0-7.2 also get a
  vendored curl. ImageMagick is built from source in every image and carries
  static libheif, libde265 and dav1d, which Trivy cannot see either.
- **PGO on real applications.** Each tier replays PrestaShop, WordPress, Laravel and Symfony (plus
  Drupal on 8.4 and 8.5) through an instrumented `php-fpm` (one static pool per app, requests sent
  over FastCGI with `php-fcgi`, pool stopped with SIGQUIT and a `process_control_timeout` long
  enough for every worker to leave through `exit()` and write its profile) under the `opcache.ini`
  the image ships, and an instrumented CLI runs a CLI workload alongside. The release build compiles
  against the merged profile. A build fails if a request does not answer 200 with the expected
  content, if a worker does not exit cleanly, if a pool's profile does not hold every worker's
  requests (clang: `fcgi_accept_request` ran at least once per request; gcc: one profile run per
  `php-fpm` process), or if pass 2 finds no usable profile for an engine, `main`, `sapi/fpm` or
  opcache object linked into `php`, `php-fpm` or `opcache.so`. A version belongs to the tier with the greatest floor at or
  below it. Pins: `php/pgo/corpus.lock`, `php/pgo/corpus/tiers`.

  | Tier floor | Serves | PrestaShop | Laravel skeleton | Symfony | WordPress | Drupal |
  |---|---|---|---|---|---|---|
  | 8.5 | 8.5 | 9.2.0 | 12.12.2 | 7 | 7.1.3 | 11.4.11 |
  | 8.4 | 8.4 | 8.2.8 | 12.12.2 | 7 | 7.1.3 | 11.4.11 |
  | 8.2 | 8.2, 8.3 | 8.2.8 | 12.12.2 | 7 | 7.1.3 | none |
  | 8.1 | 8.1 | 8.2.8 | 10.3.3 | 6.4 | 7.1.3 | none |
  | 7.2 | 7.2-8.0 | 8.2.8 | 6.20.1 | 5.4 | 6.9.10 | none |
  | 7.1 | 7.1 | 1.7.8.11 | 5.8.35 | 4.4 | 6.5.13 | none |
  | 7.0 | 7.0 | 1.6.1.24 | 5.5.28 | 3.4 | 6.5.13 | none |

- **Pinned sources.** Every fetched tarball is verified by sha256 (`deps/fetch-verified.sh`). PHP
  releases are also GPG-verified against php.net's release keys (`php/release-keys.asc`); PECL
  sources are pinned in `php/pecl.lock`. The one exception among fetched source tarballs is
  PrestaShop's en-US translation packs, fetched as `latest` because upstream re-exports them in
  place; the fetch scripts check the archive's shape instead. Two installs are not tarball-pinned:
  `cli-builder` runs an unpinned `npm install -g semantic-release`, and Composer's installer is
  verified against a signature fetched live from getcomposer.org. Source patches: [deps/patches/README.md](deps/patches/README.md).
- **Build inputs.** Each image carries `com.lotuswebagency.inputs-hash`, a hash of its build inputs
  (`scripts/inputs-hash.sh`).

## Verifying images

Every published digest has an SBOM, max-mode SLSA provenance, a keyless Cosign signature bound to
this repository's GitHub Actions workflow, signed test results, and OpenVEX statements where an
accepted finding applies.

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

Use cosign 3. Signatures and attestations are Sigstore bundles attached through the OCI 1.1 referrers
API. They are created in the GHCR staging repository `ghcr.io/lotuswebagency/php/release` and copied
to Docker Hub with the image, digest for digest, before any tag moves. A signature binds the digest,
so it verifies on `lotuswebagency/php`. The in-toto subjects of the SBOM, provenance and the two
attestations below name the staging repository with the same digests; inside the predicates, the test
result's `repository` field and the OpenVEX product identifiers name Docker Hub.

```sh
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --format '{{ json .SBOM }}'
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --format '{{ json .Provenance }}'
```

Two more attestations from the same workflow identity sit on the platform images and the multi-arch
tag:

- **Test result.** Attached only after the smoke tests and the Trivy gate passed against the pushed
  digest. It records the digest, PHP version, flavor, instruction-set variant, inputs hash, git
  commit, workflow run URL, and per architecture the smoke verdict with each passed check and the
  Trivy verdict.
- **OpenVEX.** Findings accepted instead of fixed, each with a reason and a review date. Source:
  [`vex/php.openvex.json`](vex/php.openvex.json). Only images a statement applies to carry it.
  Currently that is `cli-builder`, for `braces` in semantic-release's dependency tree, and
  `ext-builder`, for perl, which autoconf needs. Neither has a fixed release.

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

`cosign verify-attestation` prints one line per attestation on the digest, and a re-run of a release
adds another, hence `head -n1`. On a tag it checks the manifest list, which covers both
architectures. To check one platform, resolve its digest and verify `lotuswebagency/php@sha256:...`:

```sh
docker buildx imagetools inspect lotuswebagency/php:8.5-fpm --raw \
  | jq -r '.manifests[] | select(.platform.architecture == "arm64") | .digest'
```

**What Trivy sees.** The CI gate scans every flavor for fixable CRITICAL and HIGH findings and
reports none. Two findings are accepted, both without an upstream fix: CVE-2026-93687 (braces
3.0.3 in `cli-builder`'s semantic-release, HIGH) and CVE-2026-15534 (perl 5.44.0 in `ext-builder`,
MEDIUM); see [Accepted findings](SECURITY.md#accepted-findings). They are suppressed through the
`.trivyignore` generated from `vex/php.openvex.json`, so a scan without that file shows them. Trivy reads the apk database, so it does not see what is outside it:

- libraries built from source and linked statically or kept under `/opt`: ImageMagick (with static
  libheif, libde265 and dav1d) in every image; OpenSSL 1.1.1w, ICU, libxml2 and libxslt in the 7.0-8.0 images; curl in 7.0-7.2.
  libxml2 and libxslt are Debian trixie's 2.9.14 and 1.1.35 with Debian's security patches. These are
  tracked by hand through the pins in `deps/versions.lock`.
- `mariadb-dump`, `mariadb-admin` and `mariadb-check`, which are copied into the image.

Trivy ignores `affected` VEX statements and ours are all `affected`, so scanners still show those
findings. The CI gate reads a `.trivyignore` generated from the same file; each line expires on its
statement's review date. Reporting and scope: [SECURITY.md](SECURITY.md).

## Building and testing locally

`matrix.json` is the source of truth for versions. `scripts/gen_matrix.py` renders `matrix.gen.hcl`
from it and CI fails on drift. `php/ext.json` is the extension registry. Change the registry, not
the Dockerfile. Every build mounts its tier's PGO corpus image, so build the corpus first.

```sh
python3 scripts/gen_matrix.py          # after editing matrix.json
./tests/preflight.sh                   # matrix drift, PGO tiers, shellcheck, unit tests; no build
./tests/build-corpus.sh                # PGO corpus images, every tier

# bake auto-loads only docker-bake.hcl; the targets are in matrix.gen.hcl.
# Pin one platform, or arm64 builds under QEMU.
INPUTS_HASH="$(./scripts/inputs-hash.sh)" \
docker buildx bake -f matrix.gen.hcl -f docker-bake.hcl php-8_5-fpm \
  --set '*.platform=linux/amd64' --load            # one target (use `pr` for the PR subset)

./tests/smoke.sh lotuswebagency/php:8.5-fpm 8.5 fpm
./tests/test-pgo.sh lotuswebagency/php:8.5-fpm 8.5
./tests/test-ext-builder.sh 8.5        # needs that version's ext-builder, fpm and cli images
./tests/build-all.sh                   # every target, resumable; --only, --flavor, --platform, --dry-run
```

`tests/smoke.sh` fails an image whose `com.lotuswebagency.inputs-hash` label does not match the
working tree's `scripts/inputs-hash.sh` output, because a green result on a stale image proves
nothing. `tests/build-all.sh` sets the label; for a manual `bake`, set `INPUTS_HASH` as above.
`SMOKE_ALLOW_STALE=1` skips the check with a warning, for inspecting an image built elsewhere.

`smoke.sh` runs the per-image checks and calls the entrypoint, FPM health, read-only, PGO,
Snuffleupagus and ELF-hardening tests. Application suites (Laravel, WordPress, PrestaShop) are in
[tests/apps/](tests/apps/README.md). Python unit tests live in `scripts/`, `ci/` and `tests/apps/`.

`tests/extended.sh` runs the suites the main gate does not (`-v3` check, corpus-tier replay,
application suites, and on request the benchmark) against images a `develop` run pushed to GHCR,
instead of rebuilding all 50 targets. Log in to `ghcr.io` with a token that has `read:packages`, then:

```sh
tests/extended.sh pull && tests/extended.sh all
tests/extended.sh pull --only 8.4,8.5 --flavor fpm,cli
```

`pull` refuses images whose inputs hash differs from your working tree and prints the
`git worktree add` command that fixes it. Only your daemon's architecture can be tested locally.
`tests/extended.sh --help` lists the subcommands. The same suites run on native amd64 and arm64
runners through `gh workflow run extended.yml --ref develop` (inputs `sha`, `only`, `flavor`, `apps`,
`bench`).

## Releases

Work lands on `develop` through pull requests. A pull request builds, tests and Trivy-gates a subset
on amd64 without publishing. A push to `develop` builds and tests every image on native amd64 and
arm64 runners and pushes the ones that pass to `ghcr.io/lotuswebagency/php/dev` as unsigned test
builds (pruned after 14 days by `dev-prune.yml`); it never touches Docker Hub. A pull request from
`develop` to `main` is the release: merging it builds, tests, signs and attests every image in the
GHCR staging repository, copies each signed manifest list to Docker Hub with its signatures and
attestations, and only then moves the tags. A weekly rebuild (Mondays 04:10 UTC) runs on `main`.
Only the promotion and the description-sync jobs use the Docker Hub credentials, both in the
`release` deployment environment on `main`. Cadence is in [SUPPORT.md](SUPPORT.md), the controls in
[SECURITY.md](SECURITY.md).

## Repository layout

| Path | Contents |
|---|---|
| `Dockerfile` | One parameterized multi-stage build for all versions and flavors. |
| `docker-bake.hcl`, `matrix.json`, `matrix.gen.hcl` | Build targets. `matrix.gen.hcl` is generated from `matrix.json`. |
| `php/` | Extension registry (`ext.json`), pinned sources (`php-src.lock`, `pecl.lock`), build and flag scripts, PGO training (`pgo/`). |
| `deps/` | Vendored library builds (`versions.lock`, `build-*.sh`), checksum-verified fetch, [source patches](deps/patches/README.md). |
| `conf/` | Baked ini files, FPM pool config, Snuffleupagus rulesets. |
| `rootfs/usr/local/bin/` | `docker-php-entrypoint`, `php-ext-enable`, `php-fpm-healthcheck`, `php-fcgi` (FastCGI client the healthcheck uses), `sp-upload-check` (upload validator for Snuffleupagus). |
| `shim/` | Source of the `chmod(0)` `LD_PRELOAD` shim. |
| `scripts/`, `ci/` | Matrix generation, inputs hash, PGO tier checks; release, attestation, verification and VEX scripts. Both have unit tests. |
| `vex/` | OpenVEX statements for accepted findings. |
| `tests/` | Smoke, entrypoint, read-only, PGO, ext-builder and extended suites; `tests/apps/` application tests. |
| `.github/workflows/` | `ci.yml` (build, test, scan, publish), `extended.yml`, `dev-prune.yml`. |

## Migrating from `php-fpm-with-ext`

- **Config path:** the baked ini is `/usr/local/etc/php/conf.d/10-php.ini`, not `01-php.ini`. Your own
  drop-in must sort after it (`99-*.ini`).
- **Extensions:** shared extensions are enabled at runtime with `PHP_EXT_ENABLE`. Check the
  [extension list](#extensions) against what your application loads.
- **`disable_functions`:** the predecessor's default also disabled `proc_open`, `proc_close`,
  `proc_get_status`, `proc_nice`, `proc_terminate` and `highlight_file`. Here they stay enabled.
  `PHP_DISABLE_FUNCTIONS` adds to the baked list instead of replacing it.
- **JIT:** on by default here (`opcache.jit=tracing`), off in the predecessor. Set
  `PHP_OPCACHE_JIT=off` if your application has not been checked against it.
- **Healthcheck:** one pool only, via `PHP_FPM_LISTEN` and `/fpm-ping`. The predecessor's
  `FPM_HEALTH_PORTS` has no equivalent.
- **Tags:** every version ships every flavor, and `{version}` and `latest` exist for the default
  version's `fpm` image. `{version}-{flavor}` is unchanged.
- **`LD_PRELOAD`:** enable the chmod shim with `PHP_CHMOD_SHIM=true` instead of setting
  `LD_PRELOAD` yourself.

## Moving from a Debian or Alpine base

This applies to any PHP image built on Debian (the official `php:*-fpm` images, and
`dementev/php-fpm-with-ext` for 8.1 and later) or on Alpine (`dementev/php-fpm-with-ext` for
7.0-8.0). The package, path and OpenSSL notes below are written for Debian. Alpine users already
have apk, but move from musl to glibc, so rebuild every compiled extension in an `ext-builder` stage
of the same tag. Configuration and tag differences for `php-fpm-with-ext` are in the section above.

- **Packages:** `apt-get install` becomes `apk add --no-cache`, run as root (`USER root`). There is
  no `apt-get`, `dpkg` or `.deb` tooling. Package names differ: `libjpeg-dev` is
  `libjpeg-turbo-dev`, `libtiff-dev` is `tiff-dev`, `libxslt1-dev` is `libxslt-dev`, `uuid-dev` is
  `util-linux-dev`, `libpq-dev` is `postgresql-18-dev`, `libssl-dev` is `openssl-4.0-dev` (8.1
  and later). Use
  `apk search` for the rest. See [Adding your own extension](#adding-your-own-extension).
- **CPU:** the amd64 baseline needs `x86-64-v2`, which Wolfi's packages are built for. `-v3` tags
  refuse to start on an amd64 CPU below `x86-64-v3`.
- **OpenSSL:** PHP 8.1 to 8.5 use OpenSSL 4 (Debian-based images ship OpenSSL 3). An extension
  compiled against `libssl.so.3` must be rebuilt in an `ext-builder` stage of the same tag.
- **MySQL and MariaDB tools:** the client is MariaDB 13.1. `mysql`, `mysqldump`, `mysqladmin` and
  `mysqlcheck` are wrapper scripts that run the `mariadb*` tool of the same role. They prefer TLS
  but do not verify the server certificate unless given `--ssl-verify-server-cert`.
- **PHP's MySQL driver:** no PHP version supports MariaDB's `ed25519` or `parsec` accounts. PHP 7.0
  to 8.0 have further limits, listed in [Older PHP versions](#older-php-versions).
- **Paths:** there is no multiarch directory. Libraries are in `/usr/lib`, not
  `/usr/lib/x86_64-linux-gnu`.
- **Missing tools:** `ldd`, `getent`, `useradd` and `groupadd` are absent. List a binary's libraries
  with the loader (`/lib64/ld-linux-x86-64.so.2 --list <file>`, or `/lib/ld-linux-aarch64.so.1` on
  arm64). Users and groups come from busybox `adduser` and `addgroup`. `perl` is absent from `fpm`
  and `cli`.
- **Unchanged:** `www-data` is still UID and GID 33, and PID 1 is still `tini`.

## Related images

| Image | Role |
|---|---|
| [`dementev/angie`](https://hub.docker.com/r/dementev/angie) ([source](https://github.com/vdementev/angie-docker)) | Reverse proxy and TLS terminator: Angie with brotli, zstd and cache-purge |
| [`dementev/nginx`](https://hub.docker.com/r/dementev/nginx) ([source](https://github.com/vdementev/nginx-docker)) | Static sites and SPAs behind that proxy |
| **[`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php)** (this image, [source](https://github.com/LotusWebAgency/php)) | PHP 7.0 to 8.5, compiled from source with PGO, hardened |
| [`dementev/mysql-percona`](https://hub.docker.com/r/dementev/mysql-percona) ([source](https://github.com/vdementev/mysql-percona-docker)) | Percona Server for MySQL 8.4 LTS with XtraBackup |
| [`dementev/adminer`](https://hub.docker.com/r/dementev/adminer) ([source](https://github.com/vdementev/adminer-docker)) | Adminer 6 with every supported driver |

## Maintainer and license

Built and maintained by [Vasilii Dementev](https://vasiliidementev.com) at
[Lotus Web Agency](https://lotuswebagency.com). Issues and pull requests:
[github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php). Security reports:
[SECURITY.md](SECURITY.md).

Packaging in this repository is MIT licensed, see [LICENSE](LICENSE). PHP and the bundled extensions
keep their own upstream licenses.
