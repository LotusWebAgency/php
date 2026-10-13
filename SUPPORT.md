# Support and lifecycle

Every PHP version ships four flavors (`fpm`, `cli`, `cli-builder`, `ext-builder`) for `linux/amd64`
and `linux/arm64`. Tag shapes, flavors and configuration are in [README.md](README.md).

## Version matrix

Upstream status is [php.net's own](https://www.php.net/supported-versions.php), not this project's
opinion of it.

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

The EOL date is upstream's final security-support-end date. Every image carries it as the
`com.lotuswebagency.eol-date` label, and the status as `com.lotuswebagency.support` (`active`,
`security` or `end-of-life`), both from `matrix.json`. The description of an end-of-life image also
says so. Inspect them with `docker inspect` or `docker buildx imagetools inspect`.

## The end-of-life tags

They are published on purpose, so a legacy application can move onto a modern, hardened host and stay
up while it is migrated.

- **You get** a working PHP of that version, built with the same PGO training, hardening, extension
  set and configuration surface as every other tag.
- **You do not get** security fixes for the PHP runtime. Upstream stopped shipping them on the dates
  above. The weekly rebuild patches the Debian base layer, but the interpreter's source does not
  change. Treat anything at `8.1` or below as an unpatched interpreter.
- **Rebuilds are reproducible.** Each PHP release tarball is pinned by sha256 and GPG-verified
  (`php/php-src.lock`). Each PECL extension is pinned by sha256 (`php/pecl.lock`). For PHP 7.0-8.0,
  OpenSSL and ICU are vendored and pinned (`deps/versions.lock`), as is curl on 7.0-7.2. A rebuild
  produces the same interpreter, not a newer one.

The upgrade path for your application is your call. This page states the status and the date, not a
target version.

## Pinning

A tag names the PHP minor, so `8.4-fpm` moves with each 8.4 patch release. For a reproducible build,
pin the digest:

```dockerfile
FROM lotuswebagency/php:8.4-fpm@sha256:...
```

## Patch cadence

| Trigger | What happens |
|---|---|
| Push to `develop` | Every target is built on both architectures, smoke-tested and Trivy-gated. Nothing reaches Docker Hub. Tested images go to the private GHCR `php/dev` package. |
| Merge to `main` | Full build, smoke tests, Trivy gate, sign, attest, publish. |
| Weekly cron | The same pipeline with no source change, to pick up base-image and package updates. |
| Fixable CRITICAL or HIGH CVE | The build fails and nothing is published until it is fixed or accepted in `vex/php.openvex.json` with a review date. |
| PHP version bump | A commit to `matrix.json` (and the regenerated `matrix.gen.hcl`), reviewed like any other change. |

## Breaking changes

The entrypoint contract (every `PHP_*` and `PHP_FPM_*` variable in
[README.md](README.md#configuration)) and the extension registry (`php/ext.json`) are public
interface. Changes to either are called out in the pull request and covered by
`tests/test-entrypoint.sh` and `tests/smoke.sh`.

## Getting help

Open an issue at [github.com/LotusWebAgency/php/issues](https://github.com/LotusWebAgency/php/issues).
Security reports go through [SECURITY.md](SECURITY.md).
