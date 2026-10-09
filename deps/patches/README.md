# Source patches

One directory per PHP minor version, `php-<version>/`. The `php-build` stage of the `Dockerfile`
applies its patches after the release tarball is unpacked and GPG-verified, and before
`buildconf --force`:

```
patch -p1 --batch --forward --fuzz=0 < <each *.patch, in filename order>
```

- **Filename order.** Patches are named `NNN-short-description.patch`, so the glob expands in a
  deterministic order.
- **`--fuzz=0`.** Without it `patch` applies a hunk whose context only partly matches, prints
  `succeeded ... with fuzz 2` and exits 0. A patch that stops matching exactly must fail the build and
  be rewritten against the new source.
- **A missing directory is normal.** The build prints how many patches it applied, so "applied
  nothing" is visible in the log.

## Policy

A patch is the last resort. It is the only kind of change that makes the shipped binary differ from
the release tarball others audit, and the only one that breaks silently. Prefer, in order:

1. a configure flag or a version-gated build-environment change (`php/configure-args.sh`,
   `php/build.sh`, the `deps-legacy` stage);
2. a registry change (`php/ext.json`, `php/pecl.lock`);
3. a patch here.

Five of the six distinct patches are backports of fixes php-src made on a later branch. Each header
names the upstream version that carries it. The sixth, `010-curl-openssl3-not-old.patch`, is ours:
upstream never fixed it on 7.4 or 8.0 and deleted the probe in 8.4.

## Patches

| Patch | PHP | Problem | Upstream |
|---|---|---|---|
| `010-dom-iterators-libxml2-const-scanner` | 7.0 | `ext/dom` passes `itemHashScanner` to `xmlHashScan()` with a non-`const` `xmlChar *name`. libxml2 2.9.8 made it `const`, and clang 16+ treats the mismatch (`-Wincompatible-function-pointer-types`) as an error, so `ext/dom` does not build against trixie's libxml2 2.9.14. | php-src added a `#if LIBXML_VERSION >= 20908` guard in 7.1. This is that guard. |
| `020-intl-msgformat-adapter-php-prefix` | 7.0-7.3 | `ext/intl` defines `icu::MessageFormatAdapter::getArgTypeList()`, and ICU defines the same symbol in `umsg.cpp`. Harmless against a shared ICU, but a multiple-definition link error against the static ICU this project builds. | php-src renamed its methods to `phpGetArgTypeList` / `phpGetMessagePattern` in 7.4. This is that rename. |
| `030-snmp-get-gc-handler-signature` | 7.0-7.3 | `ext/snmp` defines `php_snmp_get_gc()` with `zval ***gc_data` but the `zend_object_get_gc_t` slot takes `zval **`. clang 16+ makes this an error, so `snmp.so` does not build. | php-src corrected the parameter in 7.4. |
| `040-zip-mkstemp-include-unistd` | 7.0, 7.1 | The bundled libzip `mkstemp.c` calls `getpid()` without a declaration, which clang 16+ rejects, so `--enable-zip` does not build. | php-src added the `<unistd.h>` include in 7.2. |
| `010-curl-openssl3-not-old` | 7.4, 8.0 | The `ext/curl/config.m4` probe for "libcurl linked against an old OpenSSL" only recognizes `OpenSSL/1.1` as new. Trixie's libcurl reports `OpenSSL/3.5.x`, so the probe takes the old-OpenSSL branch, which links OpenSSL into `ext/curl`. On the legacy era that resolves to the vendored static 1.1.1w, while `libcurl.so.4` is bound to the system `libssl.so.3`: two OpenSSLs with incompatible struct layouts in one process. HTTPS `curl_exec()` segfaults; plain HTTP works. The `HAVE_CURL_OLD_OPENSSL` macro defined by the same branch is not the mechanism, since its only consumer is ZTS-guarded and these images are NTS. | Not fixed upstream on these branches (both EOL). The patch adds `OpenSSL/3` alongside `OpenSSL/1.1`. |
| `010-preserve-none-probe-clobbers` | 8.5 | The `preserve_none` run-probe in `Zend/Zend.m4` writes `x20` in its aarch64 inline asm but does not list it as a clobber, so the compiler may keep an input operand there. Debian's clang 19 with ThinLTO and lld does, the probe fails with `arg2 mismatch`, `HAVE_PRESERVE_NONE` stays undefined, and arm64 silently gets the CALL VM instead of TAILCALL (`php/build.sh` fails the build on that). amd64 is unaffected; its hunk only adds `memory` and `cc`. | php-src commit `a1cb5a37c0` ("fix aarch64 gcc preserve_none detection"), applied verbatim. Remove it once an 8.5 release carries the commit; `patch --forward` fails the build if it is applied twice. |

Patches per version: 7.0: 4, 7.1: 3, 7.2: 2, 7.3: 2, 7.4: 1, 8.0: 1, 8.5: 1. PHP 8.1-8.4 need none.
7.0 is at the ceiling of four patches per version, which is the point at which a version should be
reconsidered for the matrix.

### Extension patches

`ext-<name>-<tag>/` holds patches for a GitHub-sourced extension in `php/ext.json`, keyed by the tag
its `url` pins. `php/build-shared-ext.sh` applies them with the same `patch --fuzz=0` command at the
tarball root, before descending into `subdir`, and prints the count. Keying by tag means a version
bump in `ext.json` finds no directory and applies nothing, so the patch has to be re-reviewed against
the new release to come back. No extension is patched at the moment.

### Byte-identical copies

There is no patch-range mechanism: a range is a second place that expresses version applicability and
it eventually disagrees with the directory. The duplicates are recorded here so they can be dropped
together:

- `php-7.4/` and `php-8.0/` `010-curl-openssl3-not-old.patch` (the probe region of
  `ext/curl/config.m4` is unchanged between 7.4.33 and 8.0.30).
- `php-7.1/` and `php-7.2/` `020-intl-msgformat-adapter-php-prefix.patch`. The 7.0 and 7.3 copies
  differ from these and from each other only in hunk line numbers.
- `php-7.0/` and `php-7.1/` `040-zip-mkstemp-include-unistd.patch`.
- The four `030-snmp-get-gc-handler-signature.patch` copies differ only in hunk line numbers.

Diff timestamps are stripped from every patch header so that identical changes are identical bytes.
Check with `sha256sum deps/patches/*/*.patch`.

### When each can go

- **curl:** when these versions stop being built, or when the base image's libcurl reports a version
  string the old probe understands (it will not).
- **dom, snmp, zip:** when their PHP versions are dropped, or when `snmp` / `zip` leave `php/ext.json`
  for them. These are genuine php-src bugs on branches that will not get another release.
- **intl msgformat:** if `deps/build-deps.sh` ever builds ICU shared instead of static for 7.0-7.3.
  The collision comes from the static link, not the source. Shared ICU would put an end-of-life
  library and ICU's 30 MB data blob back into every layer, which is what `--disable-shared` avoids.
- **preserve-none:** see the table.

## Adding one

1. Confirm that steps 1 and 2 of the policy cannot solve it, and say so in the patch header.
2. Write the header first: what breaks, why, which upstream version fixed it, and what would make the
   patch unnecessary. The diff is the small part.
3. Verify it applies to that exact release with zero fuzz and zero offset:
   `patch -p1 --dry-run --fuzz=0`.
4. If a version needs more than three or four patches, stop. That version does not belong in the
   matrix.
