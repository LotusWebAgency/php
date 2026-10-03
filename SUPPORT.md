# Support and lifecycle

## Tags

Every PHP version ships all four flavors:

| Flavor | What it is |
|---|---|
| `fpm` | PHP-FPM listening on `:9000`, with a FastCGI-native `HEALTHCHECK` and the PrestaShop `chmod(0)` shim available via `PHP_CHMOD_SHIM`. |
| `cli` | PHP CLI for workers, cron jobs and one-shot commands. |
| `cli-builder` | The CLI image plus Composer, git, Node.js 24 LTS and the tools a build or deploy stage needs. No compiler. Meant for a build stage, not for runtime. |
| `ext-builder` | The CLI image plus a C/C++ toolchain, the PHP headers, `phpize` and `php-config`, for compiling your own extension in a build stage and copying the `.so` into `fpm`/`cli` of the same version. Runs as root. Not for runtime. |

Tag shapes: `{version}-{flavor}` (every image), `{version}-{flavor}-v3`
(PHP 8.4/8.5 only, compiled for `x86-64-v3`/`armv9-a`; not for `ext-builder`; not for Apple silicon, where SVE2 code dies with SIGILL -- use the baseline tag on a Mac), and
`{version}`/`latest` for the default version's `fpm` image. Version tags are
read out of the built image after tests and the Trivy gate, so a tag can
never claim a version the image does not actually run.

Architectures: `linux/amd64`, `linux/arm64`.

## Version matrix

Upstream status is [php.net's own](https://www.php.net/supported-versions.php),
as of September 2026 — not this project's opinion of it.

| PHP | Upstream status | Status here | EOL date |
|---|---|---|---|
| `8.5` | Active support | Supported | 2029-12-31 |
| `8.4` | Active support | Supported | 2028-12-31 |
| `8.3` | Security fixes only | Supported | 2027-12-31 |
| `8.2` | Security fixes only | Supported | 2026-12-31 |
| `8.1` | **End of life** | Published, unpatched | 2025-12-31 |
| `8.0` | **End of life** | Published, unpatched | 2023-11-26 |
| `7.4` | **End of life** | Published, unpatched | 2022-11-28 |
| `7.3` | **End of life** | Published, unpatched | 2021-12-06 |
| `7.2` | **End of life** | Published, unpatched | 2020-11-30 |
| `7.1` | **End of life** | Published, unpatched | 2019-12-01 |
| `7.0` | **End of life** | Published, unpatched | 2019-01-10 |

`eol_date` above is upstream's own final security-support-end date — already
past for the end-of-life rows, still ahead for `security`/`active` ones.
Every published image carries the same two facts as
`com.lotuswebagency.support` (`active` / `security` / `end-of-life`) and
`com.lotuswebagency.eol-date` labels, straight from `matrix.json`, so they're
inspectable without pulling this file (`docker inspect` /
`docker buildx imagetools inspect`).

## The end-of-life tags

They are still published, deliberately, and you should understand what that
means before you pull one.

**What you get.** A working PHP of that version, compiled with the same PGO
training and hardening as every other tag, with the same extension set and
configuration surface. That is the entire value proposition: these exist so
a legacy application can be lifted onto a modern, hardened Docker host and
kept running while it is being migrated, instead of being kept alive on a
decade-old host nobody dares to touch.

**What you do not get.** Security fixes for the PHP runtime itself —
upstream stopped shipping them on the dates above, and no repackaging
changes that. The Debian base layer still gets patched by the weekly
rebuild; the interpreter's own source does not change. Anything at or below
`8.1` should be treated as running an unpatched interpreter.

**Reproducibility.** Every PHP release tarball is pinned by sha256 and
GPG-verified against php.net's release keys (`php/php-src.lock`), every
PECL extension source is pinned by sha256 (`php/pecl.lock`), and PHP 7.0–8.0's
own build dependencies (OpenSSL, ICU, curl) are vendored and pinned too
(`deps/versions.lock`) rather than pulled from whatever the base image
happens to carry. A rebuild of an end-of-life tag reproduces the same
interpreter it always did; it does not go and fetch something newer.

**If you are on one of these**, the upgrade path is a judgment call for your
own application and its dependencies — this table states the support status
and the date; it does not prescribe a target version.

## Pinning

The version in the tag is the PHP minor, not the patch — `8.4-fpm` moves as
PHP 8.4 patches land. For a reproducible build, pin the digest:

```dockerfile
FROM lotuswebagency/php:8.4-fpm@sha256:...
```

## Patch cadence

| Trigger | What happens |
|---|---|
| Push to `develop` | Full build of every target on both architectures, smoke tests, Trivy gate — nothing reaches Docker Hub; the tested images go to the private GHCR `php/dev` package |
| Merge to `main` | Full build of every target, smoke tests, Trivy gate, publish, sign |
| Weekly cron | Same pipeline, no source change — picks up base-image and package updates |
| Fixable CRITICAL/HIGH CVE | The build fails and nothing is published until it is fixed or explicitly accepted in `vex/php.openvex.json` (with a review date) |
| Real PHP version bump | A descriptive commit to `matrix.json` (and `matrix.gen.hcl`, regenerated), reviewed like any other change |

## Breaking changes

The entrypoint contract (every `PHP_*`/`PHP_FPM_*` variable documented in
[README.md](README.md#configuration)) and the extension registry
(`php/ext.json`) are treated as a public interface. Changes to either are
called out in the pull request and covered by `tests/test-entrypoint.sh` /
`tests/smoke.sh`.

## Getting help

Open an issue at
[github.com/LotusWebAgency/php/issues](https://github.com/LotusWebAgency/php/issues).
Security reports go through [SECURITY.md](SECURITY.md) instead.
