# php

PHP 7.0 through 8.5, compiled from source on `debian:trixie-slim` with profile-guided optimization
(PGO) trained on real PrestaShop, WordPress, Laravel, Symfony and Drupal applications. Binaries are
hardened at the ELF level, Snuffleupagus virtual patching is available, and a read-only root
filesystem is supported.

Docker Hub: [`lotuswebagency/php`](https://hub.docker.com/r/lotuswebagency/php).
Source: [github.com/LotusWebAgency/php](https://github.com/LotusWebAgency/php).
Coming from `dementev/php-fpm-with-ext`? See [Migrating](#migrating-from-php-fpm-with-ext).

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
| `8.2` | 8.2.34 | gcc | no | security | 2026-12-31 |
| `8.3` | 8.3.35 | gcc | no | security | 2027-12-31 |
| `8.4` | 8.4.26 | gcc | yes | active | 2028-12-31 |
| `8.5` | 8.5.11 | clang | yes | active | 2029-12-31 |

End-of-life tags are still published and rebuilt weekly for base-image and package updates. The PHP
interpreter in them gets no upstream fixes. See [SUPPORT.md](SUPPORT.md).

| Tag shape | Example | Meaning |
|---|---|---|
| `{version}-{flavor}` | `8.5-fpm` | Every baseline image. |
| `{version}-{flavor}-v3` | `8.4-fpm-v3` | Built for `x86-64-v3` / `armv9-a` instead of the `x86-64` / `armv8-a` baseline. 8.4 and 8.5 only, not for `ext-builder`. |
| `{version}`, `latest` | `8.5`, `latest` | The default version's `fpm` image (`default_version` in `matrix.json`, currently 8.5). |
| `{release}-{flavor}[-v3]` | `8.5.11-fpm` | Full patch version. Read from the built image (`PHP_VERSION`) after tests and the Trivy gate, so a tag cannot name a version the image does not contain. |

`-v3` images need a newer CPU. On amd64 older than Haswell/Excavator they refuse to start: glibc
reads a GNU property note on the `php` and `php-fpm` binaries and exits 127 with
`CPU ISA level is lower than required`. arm64 has no such check, so an unsupported core gets SIGILL. `armv9-a` code needs Neoverse N2/V2-class cores (Graviton4, Google Axion, Azure Cobalt
100, NVIDIA Grace). It does not run on Graviton2/3 or Ampere Altra. Apple M4-M6 do not provide SVE2
in normal mode, so `-v3` also dies with SIGILL in Docker Desktop and OrbStack. Use the baseline tag
on a Mac.

A tag names the PHP minor, so `8.4-fpm` moves with each 8.4 patch release. Pin the digest for
reproducible builds: `FROM lotuswebagency/php:8.4-fpm@sha256:...`.

## Flavors

| Flavor | Contents |
|---|---|
| `fpm` | PHP-FPM on `:9000` for a FastCGI-speaking reverse proxy. `STOPSIGNAL SIGQUIT` and a FastCGI `HEALTHCHECK` (`php-fpm-healthcheck`) that needs no web server. |
| `cli` | `php -a` by default. Scripts, cron jobs, queue workers. |
| `cli-builder` | `cli` plus git, rsync, patch, make, brotli, sqlite3, jq, the MariaDB client, Node.js 24 LTS with npm and corepack, semantic-release and [Composer](https://getcomposer.org/) (installed with signature verification). No compiler. For build stages. |
| `ext-builder` | `cli` plus gcc, g++, make, autoconf, pkg-config, libc6-dev and the PHP headers with `phpize` / `php-config`. Runs as root, no Composer, no Node.js. For build stages. |

All images use `tini` as PID 1. All but `ext-builder` run as `www-data` (UID 33).

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
| `PHP_OPCACHE_JIT`, `PHP_OPCACHE_JIT_BUFFER` | `tracing`, `64M` | `opcache.jit`, `opcache.jit_buffer_size`. PHP 8+ only. |
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

## Extensions

75 extensions, defined in [`php/ext.json`](php/ext.json); 74 are built (`imap` is registered but not
built: Debian trixie has no `libc-client-dev`). The registry drives configure flags, the build and
the smoke test's assertions, and lists each extension's source, linkage, PHP range and purpose.

- **53 are compiled in** and need nothing to use: the usual core set plus `igbinary`, `redis`,
  `imagick`, `memcached`, `apcu` and `zstd`.
- **21 are shared modules**, built but not loaded. Load them with `PHP_EXT_ENABLE: "ldap,uuid"`:
  `amqp`, `brotli`, `bz2`, `event`, `ffi` (7.4+), `ldap`, `lz4`, `mcrypt` (7.x),
  `mongodb` (8.1+), `msgpack`, `pcov` (7.1+), `protobuf` (8.2+), `snmp`, `snuffleupagus` (7.2+),
  `ssh2`, `swoole` (8.2+), `tidy`, `uuid`, `xdebug`, `xmlrpc` (7.x), `yaml`.

`php-ext-enable` refuses an unknown or unavailable name and lists what the image has. `xdebug` and
`snuffleupagus` load as Zend extensions automatically. `ffi` is shipped disabled because it bypasses
PHP-level sandboxing. `snmp` links a vendored client-only net-snmp in `/opt/net-snmp` instead of
Debian's `libsnmp40t64`, which pulls in perl; MIBs are shipped but not loaded (set `MIBS=ALL` in the
environment or `mibs +ALL` in `/etc/snmp/snmp.conf`).

### Adding your own extension

The images carry no `pecl`, `pear` or `docker-php-ext-install`. Compile in an `ext-builder` stage
and copy only the `.so`:

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
- Install runtime libraries (`libmyext1`, not `-dev`) in the final stage as root, then switch back
  to `www-data`.
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
- **Control-flow protection** (`-fcf-protection=full`, amd64): every function entry has an `endbr64`
  landing pad. The loader-enforced IBT/SHSTK property note is not claimed, because Debian trixie's
  own toolchain does not emit it.
- Every link uses `-z relro -z now -z noexecstack --as-needed --build-id=sha1`.
- Every setuid and setgid bit inherited from the base image is stripped.

**Snuffleupagus.** [Virtual patching](https://github.com/jvoisin/snuffleupagus) is compiled in but
not loaded by default. Four rulesets are baked into `/usr/local/etc/php/snuffleupagus/`: `default`,
`wordpress`, `prestashop` and `laravel`. Enable one with `PHP_SNUFFLEUPAGUS=prestashop`. Snuffleupagus is not available on PHP 7.0 and 7.1. Rulesets are
for serving; build and deploy (Composer included) with `cli-builder` and no ruleset. No ruleset enables
`readonly_exec`; the PrestaShop one disables it explicitly because PrestaShop rewrites its own cache
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

- **Compiler per PHP era** (`compiler` in `matrix.json`). PHP 7.0-8.4 build with GCC 16.2, PGO and no
  LTO, because GCC's LTO rejects the HYBRID VM's global register variables. PHP 8.5 builds with
  Debian's clang 19, PGO and ThinLTO, which gives the TAILCALL VM. `-std=gnu17` is pinned for every
  version, because GCC 15's `gnu23` default breaks K&R-style code in php-src and PECL sources.
- **Dependencies by era.** PHP 8.1+ uses Debian packages. PHP 7.0-8.0 uses OpenSSL and ICU vendored
  from `deps/versions.lock` and linked statically, so no end-of-life `libssl.so` ships. PHP 7.0-7.2
  also get a vendored curl. ImageMagick and net-snmp are built from source in every image.
- **PGO on real applications.** Each tier replays PrestaShop, WordPress, Laravel and Symfony (plus
  Drupal on 8.4 and 8.5) through `php-fpm` under the shipped `conf/opcache.ini`, and the release
  build compiles against that profile. A version belongs to the tier with the greatest floor at or
  below it. Pins: `php/pgo/corpus.lock`, `php/pgo/corpus/tiers`.

  | Tier floor | Serves | PrestaShop | Laravel skeleton | Symfony | WordPress | Drupal |
  |---|---|---|---|---|---|---|
  | 8.5 | 8.5 | 9.2.0 | 12.12.2 | 7 | 7.0.6 | 11.4.8 |
  | 8.4 | 8.4 | 8.2.8 | 12.12.2 | 7 | 7.0.6 | 11.4.8 |
  | 8.2 | 8.2, 8.3 | 8.2.8 | 12.12.2 | 7 | 7.0.6 | none |
  | 8.1 | 8.1 | 8.2.8 | 10.3.3 | 6.4 | 7.0.6 | none |
  | 7.2 | 7.2-8.0 | 8.2.8 | 6.20.1 | 5.4 | 6.9.9 | none |
  | 7.1 | 7.1 | 1.7.8.11 | 5.8.35 | 4.4 | 6.5.12 | none |
  | 7.0 | 7.0 | 1.6.1.24 | 5.5.28 | 3.4 | 6.5.12 | none |

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
  Currently that is `cli-builder`, for `brace-expansion` and `undici` inside the npm that Node
  bundles.

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

`tests/extended.sh` runs the suites the main gate skips (`-v3` check, ext-builder, corpus-tier replay,
application suites, benchmark) against images a `develop` run pushed to GHCR, instead of rebuilding
all 50 targets. Log in to `ghcr.io` with a token that has `read:packages`, then:

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
| `rootfs/usr/local/bin/` | `docker-php-entrypoint`, `php-ext-enable`, `php-fpm-healthcheck`, `sp-upload-check` (upload validator for Snuffleupagus). |
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
