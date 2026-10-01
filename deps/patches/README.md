# Source patches applied to php-src and extensions

One directory per PHP minor version, `php-<version>/`, applied by the
`php-build` stage of the `Dockerfile` after the release tarball is unpacked and
GPG-verified, and before `buildconf --force`:

```
patch -p1 --batch --forward --fuzz=0 < <each *.patch, in filename order>
```

Three things follow from that command, and all three are deliberate:

* **Filename order.** Patches are named `NNN-short-description.patch` so `*`
  expands in a deterministic order rather than a locale-dependent one.
* **`--fuzz=0`.** `patch` will otherwise apply a hunk whose context only partly
  matches, print `Hunk #1 succeeded at 42 with fuzz 2`, and exit 0. On a
  security-relevant binary that is a silent behaviour change wearing a green
  build's clothes. A patch that stops matching its context exactly must fail
  the build and be rewritten against the new source, not fuzzed into place.
* **A missing directory is normal.** Most versions need no patches at all. The
  build echoes how many it applied, so "applied nothing" is visible in the log
  rather than indistinguishable from "applied everything".

## Policy: this is the last resort, not the first

The task 1 spike's most useful result was that PHP 7.0 needed **zero** source
patches to build on trixie: every incompatibility it found was fixable with a
flag, a shim or a pin. Task 15, which built
the other ten versions, kept that shape. **Five of the six** distinct php-src
patches here are **backports of fixes php-src itself later made** — not new code, each
naming the upstream version that carries it. The sixth,
`010-curl-openssl3-not-old.patch`, is the exception: upstream never fixed it on
7.4 or 8.0 (both EOL by then) and simply deleted the probe in 8.4, so that one
is ours. Prefer, in order:

1. a configure flag or a version-gated build-environment change
   (`php/configure-args.sh`, `php/build.sh`, the `deps-legacy` stage);
2. a registry change (`php/ext.json`, `php/pecl.lock`);
3. a patch here.

The reason to prefer 1 and 2 is not aesthetics: a patch is the only one of the
three that makes the shipped binary differ from the release tarball everyone
else audits, and the only one whose breakage mode is silent.

## What is here

| version | patch | fixes | upstream |
|---|---|---|---|
| 7.0 | `010-dom-iterators-libxml2-const-scanner.patch` | `ext/dom`'s `itemHashScanner` is passed to `xmlHashScan()` with a non-`const` `xmlChar *name`, which libxml2 changed to `const` in 2.9.8. clang 16+ makes that mismatch (`-Wincompatible-function-pointer-types`) an error by default, so `ext/dom` does not compile against trixie's libxml2 2.9.14. | php-src fixed it in **7.1** with a `#if LIBXML_VERSION >= 20908` guard; this is that guard, verbatim. 7.1-8.0 already carry it. |
| 7.0 | `020-intl-msgformat-adapter-php-prefix.patch` | `ext/intl` defines `icu::MessageFormatAdapter::getArgTypeList()` itself, and ICU defines the same symbol in `umsg.cpp`. Invisible against a shared libicui18n; a **multiple definition** link error against the static one this project builds, at the final link of `sapi/cli/php`. | php-src renamed its own methods to `phpGetArgTypeList`/`phpGetMessagePattern` in **7.4**, explicitly "to avoid clashes with any definitions in ICU". This is that rename. |
| 7.1 | `020-intl-msgformat-adapter-php-prefix.patch` | same | same |
| 7.2 | `020-intl-msgformat-adapter-php-prefix.patch` | same | same |
| 7.3 | `020-intl-msgformat-adapter-php-prefix.patch` | same | same |
| 7.0 | `030-snmp-get-gc-handler-signature.patch` | `ext/snmp` defines `php_snmp_get_gc()` with `zval ***gc_data` and assigns it to a `zend_object_get_gc_t` slot that has taken `zval **` since 7.0 — one indirection too many. clang 16+ makes `-Wincompatible-function-pointer-types` an error, so `snmp.so` no longer builds. | php-src corrected the parameter to `zval **` in **7.4**, body unchanged. This is that correction. |
| 7.1 | `030-snmp-get-gc-handler-signature.patch` | same | same |
| 7.2 | `030-snmp-get-gc-handler-signature.patch` | same | same |
| 7.3 | `030-snmp-get-gc-handler-signature.patch` | same | same |
| 7.0 | `040-zip-mkstemp-include-unistd.patch` | The bundled libzip's `mkstemp.c` calls `getpid()` with no declaration in scope, which clang 16+ rejects outright, so `--enable-zip` does not compile. | php-src added `#ifndef _WIN32 / #include <unistd.h>` in **7.2**; 7.2 and 7.3 already carry it. |
| 7.1 | `040-zip-mkstemp-include-unistd.patch` | same | same |
| 7.4 | `010-curl-openssl3-not-old.patch` | `ext/curl/config.m4`'s "is libcurl linked against an old OpenSSL" probe only recognises `OpenSSL/1.1` as new. Trixie's libcurl reports `OpenSSL/3.5.x`, so the probe takes its old-OpenSSL branch — and that branch runs `PKG_CHECK_MODULES([OPENSSL])` + `PHP_EVAL_LIBLINE`, which links OpenSSL into `ext/curl`. On the legacy era pkg-config resolves that to the **vendored static 1.1.1w**, while the `libcurl.so.4` the extension calls is bound to the system `libssl.so.3`: two OpenSSLs, incompatible struct layouts, one address space. HTTPS `curl_exec()` segfaults; plain HTTP works. (The `HAVE_CURL_OLD_OPENSSL` macro the same branch defines is **not** the mechanism — its only consumer is ZTS-guarded and these images are NTS.) | Not fixed upstream on these branches (both EOL); the probe predates OpenSSL 3. Adds `OpenSSL/3` to the same branch as `OpenSSL/1.1`. |
| 8.0 | `010-curl-openssl3-not-old.patch` | same | same |

Four of the five distinct php-src patches (the six less the 8.1-8.3 xxhash one,
now upstream) are backports of fixes php-src made itself on
a later branch; the curl one is ours, because upstream deleted the offending
probe in 8.4 rather than fixing it on the EOL branches. None changes behaviour
upstream did not also change in effect (the snuffleupagus patch further down
does, and says so). Per version the counts are 7.0: 4, 7.1: 3,
7.2: 2, 7.3: 2, 7.4: 1, 8.0: 1. 7.0 sits exactly at the
four-patch ceiling this project set for a single version, which is worth
knowing when the question of retiring 7.0 next comes up.

**No patches needed:** 8.1–8.5. 8.1–8.3 carried a backport of php-src's
`"xxhash/xxhash.h"` qualified include (the bundled zstd in the statically built
`ext/zstd` shadowed `ext/hash`'s `xxhash.h`) until 8.1.34 / 8.2.34 / 8.3.35 shipped
the same change upstream; with it applied twice `patch --forward` fails the build.

### Extension patches

`ext-<name>-<tag>/` holds patches for a github-sourced extension in
`php/ext.json`, keyed by the tag its `url` pins. `php/build-shared-ext.sh`
applies them with the same `patch --fuzz=0` command, at the tarball root before
it descends into `subdir`, and echoes the count. Keying by tag is deliberate: a
version bump in `ext.json` finds no directory, applies nothing, says so, and
the patch has to be re-reviewed against the new release to come back.

| extension | patch | fixes | upstream |
|---|---|---|---|
| snuffleupagus v0.14.0 | `010-xxe-quiet-disable-entity-loader.patch` | The xxe hook logs an E_WARNING on every nopped `libxml_disable_entity_loader()` call. Symfony makes that call on every XSD validation on PHP 7, so PrestaShop 8.2 on 7.2-7.4 logged over a thousand per app-suite run, and PrestaShop's webservice turns a warning into an error response. Only the log line goes; the call stays a nop. | Not fixed upstream. Ours, and a behaviour change rather than a backport -- the exception to this file's policy, taken because no rule or config reaches that log line. |

### Byte-identical copies

There is no patch-range mechanism, by design — a range is a second place where
version applicability is expressed, and it disagrees with the directory
eventually. The duplication is accepted and recorded here instead, so copies
can be dropped together when they become unnecessary:

* `php-7.4/010-curl-openssl3-not-old.patch` and
  `php-8.0/010-curl-openssl3-not-old.patch` are byte-identical
  (`ext/curl/config.m4`'s probe region is unchanged between 7.4.33 and 8.0.30).
* `php-7.1/` and `php-7.2/`'s `020-intl-msgformat-adapter-php-prefix.patch` are
  byte-identical. `php-7.0/`'s and `php-7.3/`'s differ from them, and from each
  other, only in hunk line numbers -- the changed lines are the same eight.
* `php-7.0/` and `php-7.1/`'s `040-zip-mkstemp-include-unistd.patch` are
  byte-identical.
* The four `030-snmp-get-gc-handler-signature.patch` copies differ only in hunk
  line numbers; the changed line is the same one.

(Diff timestamps are stripped from every patch header here for exactly this
reason: two patches that are the same change should be the same bytes, and a
`diff -u` timestamp makes that impossible to see.)

### When each can be dropped

* **The curl patches** disappear if these versions ever stop being built, or if
  the base image's libcurl ever reports a version string the 2020-era probe
  understands (it will not).
* **The dom patch** disappears if 7.0 is dropped.
* **The snmp and zip patches** disappear when their versions are dropped, or if
  `snmp`/`zip` are ever removed from `php/ext.json` for them. Both are genuine
  php-src bugs on branches that will never get another release, so upstream
  will not fix them again.
* **The intl msgformat patches** disappear if `deps/build-deps.sh` ever builds
  ICU shared instead of static for 7.0-7.3 -- the collision is a consequence of
  the static link, not of the source. That trade is not worth making: a shared
  EOL ICU in the image is exactly what `--disable-shared` exists to prevent,
  and it would add ICU's 30 MB data blob back to every layer.

## Adding one

1. Establish that steps 1 and 2 above genuinely cannot solve it, and say so in
   the patch's own header.
2. Write the header first: what breaks, why, which upstream version fixed it,
   and what would make the patch unnecessary. The diff is the small part.
3. Verify it applies with **zero fuzz and zero offset** against that exact
   release: `patch -p1 --dry-run --fuzz=0`.
4. If a version needs more than three or four patches, stop. That is the signal
   that the version does not belong in the matrix, not that the patch pile
   needs to be taller.
