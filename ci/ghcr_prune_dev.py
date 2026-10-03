#!/usr/bin/env python3
"""Retention for the develop images in GHCR (ghcr.io/lotuswebagency/php/dev).

    python3 ci/ghcr_prune_dev.py --dry-run     # print the plan, delete nothing
    python3 ci/ghcr_prune_dev.py               # delete what the plan says

Runs `gh api` (GH_TOKEN with packages: write) against the one package
`php/dev` -- hardcoded, there is no option to name another, so the hash-pinned
PGO corpora in `php/corpus` and the build cache can never be reached from here.

The dev images are tagged `<tag>-<sha>-<arch>` (one version each), `<tag>-<sha>`
(the manifest list) and the floating `<tag>`. The floating tag and the list it
points at are the same digest, hence the same package version, so the sha of a
floating tag is read from the `<tag>-<sha>` tag that version also carries.

    * a version carrying a floating tag is never deleted, and neither is any
      version of a sha such a version belongs to (the set a pull of any floating
      tag can lead to), nor of the newest sha overall, whatever their age;
    * any other tagged version goes once the newest version of every sha it
      belongs to is older than RETENTION_DAYS (default 14);
    * an untagged version goes only if it is older than that AND no kept manifest
      list names its digest as a child. When the children cannot be resolved the
      untagged versions are all kept.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys

ORG = "LotusWebAgency"
PACKAGE = "php/dev"
DEFAULT_RETENTION_DAYS = 14
IMAGE_REPO = "ghcr.io/lotuswebagency/php/dev"

SHA_TAG = re.compile(r"^(?P<tag>.+)-(?P<sha>[0-9a-f]{12})(?:-(?P<arch>amd64|arm64))?$")


def package_url(org=ORG, package=PACKAGE):
    if (org, package) != (ORG, PACKAGE):
        raise SystemExit(f"refusing to touch {org}/{package}: only {ORG}/{PACKAGE} is ever pruned")
    return f"/orgs/{org}/packages/container/{package.replace('/', '%2F')}/versions"


def parse_tag(tag):
    """(floating-tag-name, sha, arch) for a sha tag, None for a floating one."""
    m = SHA_TAG.match(tag)
    return (m["tag"], m["sha"], m["arch"]) if m else None


def tags_of(version):
    return (version.get("metadata", {}).get("container", {}).get("tags")) or []


def timestamp(version):
    stamps = [version[k] for k in ("created_at", "updated_at") if version.get(k)]
    return max(datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) for s in stamps)


def shas_of(version):
    return {p[1] for p in map(parse_tag, tags_of(version)) if p}


def is_floating(version):
    return any(parse_tag(t) is None for t in tags_of(version))


def plan(versions, now, retention_days, children_of):
    """Decide every version's fate.

    children_of(digest) -> set of child digests of that manifest list; it may
    raise, in which case no untagged version is deleted.
    Returns (keep, delete, notes): keep and delete are lists of (version, reason).
    """
    cutoff = now - datetime.timedelta(days=retention_days)
    notes = []

    newest = {}
    for v in versions:
        for sha in shas_of(v):
            newest[sha] = max(newest.get(sha, timestamp(v)), timestamp(v))

    kept_shas = set()
    for v in versions:
        if is_floating(v):
            shas = shas_of(v)
            if not shas:
                notes.append(f"version {v['id']} carries floating tag(s) {tags_of(v)} but no <tag>-<sha> tag")
            kept_shas |= shas
    if newest:
        kept_shas.add(max(newest, key=newest.get))

    keep, delete, untagged = [], [], []
    for v in versions:
        if is_floating(v):
            keep.append((v, "carries a floating tag"))
        elif not tags_of(v):
            untagged.append(v)
        elif shas_of(v) & kept_shas:
            keep.append((v, "sha " + ",".join(sorted(shas_of(v) & kept_shas)) + " is kept"))
        elif max(newest[s] for s in shas_of(v)) >= cutoff:
            keep.append((v, "newest version of its sha is within retention"))
        else:
            delete.append((v, "sha older than retention and not floating"))

    old_untagged = [v for v in untagged if timestamp(v) < cutoff]
    for v in untagged:
        if v not in old_untagged:
            keep.append((v, "untagged, within retention"))
    if not old_untagged:
        return keep, delete, notes

    referenced = set()
    try:
        for v, _ in keep:
            if any(p is None or p[2] is None for p in map(parse_tag, tags_of(v))):
                referenced |= children_of(v["name"])
    except Exception as exc:  # when in doubt, keep
        notes.append(f"could not resolve manifest list children ({exc}): keeping every untagged version")
        keep.extend((v, "untagged, children unresolved") for v in old_untagged)
        return keep, delete, notes
    for v in old_untagged:
        if v["name"] in referenced:
            keep.append((v, "untagged but referenced by a kept manifest list"))
        else:
            delete.append((v, "untagged, older than retention, unreferenced"))
    return keep, delete, notes


def gh_json_pages(args):
    out = subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True).stdout
    decoder, pos, items = json.JSONDecoder(), 0, []
    while pos < len(out):
        while pos < len(out) and out[pos].isspace():
            pos += 1
        if pos >= len(out):
            break
        page, pos = decoder.raw_decode(out, pos)
        items.extend(page)
    return items


def list_versions():
    return gh_json_pages(["--paginate", f"{package_url()}?per_page=100"])


def registry_children(digest):
    raw = subprocess.run(
        ["docker", "buildx", "imagetools", "inspect", "--raw", f"{IMAGE_REPO}@{digest}"],
        check=True, capture_output=True, text=True,
    ).stdout
    return {m["digest"] for m in json.loads(raw).get("manifests", [])}


def delete_version(version_id):
    r = subprocess.run(["gh", "api", "-X", "DELETE", f"{package_url()}/{int(version_id)}"],
                       capture_output=True, text=True)
    if r.returncode != 0 and "404" not in r.stderr:
        raise RuntimeError(f"delete {version_id} failed: {r.stderr.strip()}")


def describe(version):
    return ",".join(tags_of(version)) or "<untagged>"


def main(argv=None, now=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print the plan, delete nothing")
    ap.add_argument("--retention-days", type=int,
                    default=int(os.environ.get("RETENTION_DAYS") or DEFAULT_RETENTION_DAYS))
    args = ap.parse_args(argv)

    versions = list_versions()
    now = now or datetime.datetime.now(datetime.timezone.utc)
    keep, delete, notes = plan(versions, now, args.retention_days, registry_children)

    for note in notes:
        print(f"::warning::{note}")
    print(f"{PACKAGE}: {len(versions)} versions, keep {len(keep)}, delete {len(delete)} "
          f"(retention {args.retention_days} days{', dry run' if args.dry_run else ''})")
    for v, why in delete:
        print(f"  delete {v['id']} {v['name'][:19]} [{describe(v)}] {timestamp(v):%Y-%m-%d}: {why}")

    if args.dry_run:
        return 0
    failed = 0
    for v, _ in delete:
        try:
            delete_version(v["id"])
        except RuntimeError as exc:
            failed += 1
            print(f"::error::{exc}")
    print(f"deleted {len(delete) - failed}, failed {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
