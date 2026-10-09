# Security policy

## Reporting a vulnerability

Report privately, not in a public issue. Use
[GitHub private vulnerability reporting](https://github.com/LotusWebAgency/php/security/advisories/new)
on this repository.

Useful in a report: the tag or digest, the CVE or a reproduction, and what an attacker gets. If you
have a fix, a pull request is welcome, but send the report first.

## Response targets

Business days, Asia/Bangkok.

| Stage | Target |
|---|---|
| Acknowledgement | 2 business days |
| Triage and severity call | 5 business days |
| Published fix: fixable CRITICAL or HIGH | 7 days from triage |
| Published fix: everything else | the next weekly rebuild |

Fixes ship as a rebuild of the current tags, so `docker pull` is the upgrade path. Tag lifecycle and
rebuild cadence: [SUPPORT.md](SUPPORT.md).

## What is automated

Every build (pull request, push to `develop`, merge to `main`, weekly rebuild) runs a Trivy scan and
fails on any fixable CRITICAL or HIGH finding before an image can be published.

Trivy scans the OS package layer. It cannot see libraries built from source and vendored under `/opt`:
ImageMagick and net-snmp in every image, and OpenSSL, ICU (and curl on 7.0-7.2) in the 7.0-8.0 images.
Those are tracked by hand through the pins in `deps/versions.lock`.

Only `main` publishes. A release is built, tested, signed and attested in a GHCR staging repository,
then each multi-arch list is copied to Docker Hub with its signatures and attestations and tagged
there. `develop` builds push only unsigned test images to a private GHCR package. Two jobs use the
Docker Hub credentials, the promotion and the description sync. Both run on `main` only, in the
`release` deployment environment. Restricting that environment's secrets to `main` is a repository
setting the workflow cannot enforce.

Published digests carry an SBOM, max-mode SLSA provenance, a keyless Cosign signature, signed test
results, and OpenVEX statements where an accepted finding applies. Verify what you pulled:

```sh
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity 'https://github.com/LotusWebAgency/php/.github/workflows/ci.yml@refs/heads/main' \
  lotuswebagency/php:8.5-fpm
```

Use cosign 3. The commands for the test-result and OpenVEX attestations, and notes on where the
signatures are created, are in [README.md](README.md#verifying-images).

## Accepted findings

Findings that are accepted rather than fixed (no upstream fix, or not reachable in the image) are
recorded in [`vex/php.openvex.json`](vex/php.openvex.json), the single source of truth. Each has a
reason, the affected package as a purl, and a `review-by: YYYY-MM-DD` date in its `status_notes`.
`.trivyignore` is generated from that file (`python3 ci/vex.py trivyignore --write`), and each line
expires on the review date. From that date the Trivy gate fails the build on the finding again and
nothing is published until it is fixed or the statement is renewed. CI annotates a warning in the 14
days before the date (`python3 ci/vex.py check --warn-within 14`).

Trivy ignores `affected` statements, and ours are all `affected` (accepted, no upstream fix, not
claimed unreachable), so scanners still show these findings.

## Scope

In scope: anything shipped from this repository and anything in a published `lotuswebagency/php`
image.

Out of scope:

- Vulnerabilities in upstream projects we only compile and package (PHP, a PECL extension,
  Snuffleupagus). Report those upstream, and tell us so we can pin or patch around them.
- Findings that need an already-compromised host or Docker daemon.
- The absence of upstream PHP security fixes on an end-of-life tag. That is a documented property of
  the tag (see [SUPPORT.md](SUPPORT.md)), not a defect here.
- Unfixable CVEs already recorded in `vex/php.openvex.json` with a reason.

Not a defect: Snuffleupagus's XXE feature (`sp.xxe_protection`) is not enabled in the shipped
rulesets, because it does not hold across requests and on PHP 7 it disables the application's own
`libxml_disable_entity_loader()`. libxml2 2.9 and later loads external entities only if the
application opts in (`LIBXML_NOENT`, `LIBXML_DTDLOAD`). On PHP 7, call
`libxml_disable_entity_loader(true)` yourself.
