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
Published digests carry an SBOM, max-mode SLSA provenance, a keyless Cosign
signature and signed test results, plus OpenVEX statements where an accepted
finding applies.

Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
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

Findings that are accepted rather than fixed (no upstream fix available, or
not reachable in this image) are recorded in
[`vex/php.openvex.json`](vex/php.openvex.json), the one source of truth, with
the reason, the affected package as a purl and a `review-by` date. The `.trivyignore`
the gate reads is generated from it, and each line expires on that date: from the
review date on, the Trivy gate fails the build on the finding again and nothing
is published until it is fixed or the statement is renewed, so no acceptance
outlives its review. CI annotates a warning in the 14 days before the date
(`python3 ci/vex.py check --warn-within 14`); it does not fail until Trivy does.

## Scope

In scope: anything shipped from this repository, and anything in a published
`lotuswebagency/php` image.

Out of scope: vulnerabilities in upstream projects that we only compile and
package (PHP itself, a PECL extension, Snuffleupagus) — report those
upstream, and tell us so we can pin or patch around them; findings that
require an already-compromised host or Docker daemon; the *absence* of
upstream PHP security fixes on an end-of-life version tag, which is a
documented property of that tag (see [SUPPORT.md](SUPPORT.md)), not a defect
in this repository; and unfixable CVEs already recorded in `vex/php.openvex.json` with
a reason.

Not a defect: Snuffleupagus's XXE feature (`sp.xxe_protection`) is not enabled
in the shipped rulesets, because it does not hold across requests and on PHP 7
nops the application's own `libxml_disable_entity_loader()`. libxml2 ≥ 2.9
does not load external entities unless the application opts in
(`LIBXML_NOENT`, `LIBXML_DTDLOAD`); on PHP 7, apps should call
`libxml_disable_entity_loader(true)` themselves.
