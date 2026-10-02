# Security policy

## Reporting a vulnerability

Please report privately rather than opening a public issue: use
[GitHub private vulnerability reporting](https://github.com/LotusWebAgency/php/security/advisories/new)
on this repository.

Useful in a report: the tag or digest you found it in, the CVE or a
reproduction, and what an attacker gets out of it. If you have a fix, a pull
request is welcome, but send the report first.

## Response targets

Business days, Asia/Bangkok.

| Stage | Target |
|---|---|
| Acknowledgement | 2 business days |
| Triage and severity call | 5 business days |
| Published fix — fixable CRITICAL or HIGH | 7 days from triage |
| Published fix — everything else | the next weekly rebuild |

Fixes ship as a rebuild of the current tags, so `docker pull` is the upgrade
path. Tag lifecycle and rebuild cadence are described in [SUPPORT.md](SUPPORT.md).

## What is already automated

Every build — pull request, push to `develop`, merge to `main`, or the weekly
rebuild — runs a Trivy scan and fails on any *fixable* CRITICAL or HIGH finding before an image can be
published, so a known-vulnerable Debian package cannot ship silently. Trivy
scans the OS package layer; it cannot see the libraries built from source and
vendored under `/opt` (ImageMagick and net-snmp in every build, the vendored
OpenSSL, ICU and, on 7.0–7.2, curl in the 7.0–8.0 builds), since those never
touch a package manager. Those are tracked by hand instead, through the
pinned versions in `deps/versions.lock`. Only `main` publishes, and `main` is
branch-protected: publishing requires a green pull request (work lands on
`develop`, which builds and tests both architectures but never publishes).
Published digests carry an SBOM, max-mode SLSA provenance and a keyless Cosign
signature.

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

Findings that are accepted rather than fixed (no upstream fix available, or
not reachable in this image) are recorded in a `.trivyignore` file in this
repository together with the reason, so the gate stays meaningful instead of
being switched off.

## Scope

In scope: anything shipped from this repository, and anything in a published
`lotuswebagency/php` image.

Out of scope: vulnerabilities in upstream projects that we only compile and
package (PHP itself, a PECL extension, Snuffleupagus) — report those
upstream, and tell us so we can pin or patch around them; findings that
require an already-compromised host or Docker daemon; the *absence* of
upstream PHP security fixes on an end-of-life version tag, which is a
documented property of that tag (see [SUPPORT.md](SUPPORT.md)), not a defect
in this repository; and unfixable CVEs already listed in `.trivyignore` with
a reason.

Not a defect: Snuffleupagus's XXE feature (`sp.xxe_protection`) is not enabled
in the shipped rulesets, because it does not hold across requests and on PHP 7
nops the application's own `libxml_disable_entity_loader()`. libxml2 ≥ 2.9
does not load external entities unless the application opts in
(`LIBXML_NOENT`, `LIBXML_DTDLOAD`); on PHP 7, apps should call
`libxml_disable_entity_loader(true)` themselves.
