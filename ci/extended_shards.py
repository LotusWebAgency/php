#!/usr/bin/env python3
"""Shards of an extended.yml `versions` job.

    python3 ci/extended_shards.py plan [--only CSV] [--flavor CSV] [--apps true|false] [--table]
    python3 ci/extended_shards.py resolve <shard-id> [--flavor CSV]

A shard id is `X.Y` (the whole version) or `X.Y~fpm` / `X.Y~cli` (half of one).
`plan` prints the ids as a JSON array, longest first, which is what the job
matrix expands (matrix jobs start in array order, so the long ones start first
and the 20-job concurrency cap does not park them behind the short ones).

A version is split when its estimated minutes reach EXT_SHARD_MIN (default 25)
and both halves have app steps: the `fpm` half runs the fpm images' suites, the
`cli` half those of cli and cli-builder. The extras (pull of every flavor, uarch,
ext-builder, jit-stress) stay together in the `fpm` half: ext-builder needs the
fpm, cli and ext-builder images of one version, and the fpm half is the lighter.
Nothing is split when the apps are off: the halves would have no suites to share.

The estimate is minutes = SETUP + PER_STEP * app steps (+ EXTRAS), steps being
what tests/apps/run-matrix.sh --list reports as `step(s)` (fpm: one per config,
cli-builder: 2, cli: 1). The constants are fitted to the 8.4 amd64 run (44 min:
35 steps, ~5 min of extras); they only balance the shards, nothing else reads them.

`resolve` prints key=value lines for ci/extended-run.sh: the version, the flavors
the pull and the extras run with (`pull_flavor`, empty = all), the flavors of the
app suites (`apps_flavor`) and whether this shard carries the extras. The user's
--flavor selection narrows every list; an empty result is an error.
"""
import argparse
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SETUP_MIN = 3.0
PER_STEP_MIN = 1.05
EXTRAS_MIN = 5.5
DEFAULT_SHARD_MIN = 25.0
GROUPS = {"fpm": ("fpm",), "cli": ("cli", "cli-builder")}


def csv(s):
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def version_key(v):
    return tuple(int(x) for x in v.split("."))


def matrix_versions():
    with open(os.path.join(ROOT, "matrix.json")) as f:
        return sorted(json.load(f)["versions"], key=version_key)


def read_cells(versions):
    """[(php, flavor, configs)] of tests/apps/sets for these versions."""
    out = subprocess.run(
        [sys.executable, os.path.join(ROOT, "tests/apps/appsets.py"), "cells", "--php", ",".join(versions)],
        check=True, capture_output=True, text=True).stdout
    cells = []
    for line in out.splitlines():
        _app, _set, php, flavor, _variant, configs = line.split("\t")
        cells.append((php, flavor, len(csv(configs))))
    return cells


def steps_of(flavor, configs):
    return configs if flavor == "fpm" else 2 if flavor == "cli-builder" else 1


def group_of(flavor):
    return next((g for g, fl in GROUPS.items() if flavor in fl), None)


def plan(versions, flavors, apps, cells, shard_min=DEFAULT_SHARD_MIN):
    """[{id, version, minutes}] longest first; ties keep version order."""
    extras = EXTRAS_MIN if not flavors or "ext-builder" in flavors else 0.0
    shards = []
    for v in versions:
        steps = {"fpm": 0, "cli": 0}
        for php, flavor, configs in cells:
            g = group_of(flavor)
            if php == v and g and (not flavors or flavor in flavors):
                steps[g] += steps_of(flavor, configs)
        whole = SETUP_MIN + PER_STEP_MIN * (steps["fpm"] + steps["cli"]) + extras
        if apps and steps["fpm"] and steps["cli"] and whole >= shard_min:
            shards.append({"id": f"{v}~fpm", "version": v,
                           "minutes": SETUP_MIN + PER_STEP_MIN * steps["fpm"] + extras})
            shards.append({"id": f"{v}~cli", "version": v,
                           "minutes": SETUP_MIN + PER_STEP_MIN * steps["cli"]})
        else:
            shards.append({"id": v, "version": v,
                           "minutes": SETUP_MIN + PER_STEP_MIN * (steps["fpm"] + steps["cli"] if apps else 0) + extras})
    return sorted(shards, key=lambda s: -s["minutes"])


def resolve(shard_id, flavors):
    version, _, group = shard_id.partition("~")
    if group and group not in GROUPS:
        raise SystemExit(f"'{shard_id}': the part after ~ must be one of {', '.join(GROUPS)}")
    version_key(version)
    if not group:
        return {"version": version, "pull_flavor": ",".join(flavors),
                "apps_flavor": ",".join(flavors), "extras": "true"}
    mine = [f for f in GROUPS[group] if not flavors or f in flavors]
    if not mine:
        raise SystemExit(f"shard {shard_id} has no flavor left under --flavor {','.join(flavors)}")
    return {"version": version,
            "pull_flavor": ",".join(flavors) if group == "fpm" else ",".join(mine),
            "apps_flavor": ",".join(mine),
            "extras": "true" if group == "fpm" else "false"}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--only", default="")
    p.add_argument("--flavor", default="")
    p.add_argument("--apps", default="true")
    p.add_argument("--table", action="store_true", help="print a markdown table instead of the JSON array")
    r = sub.add_parser("resolve")
    r.add_argument("shard")
    r.add_argument("--flavor", default="")
    args = ap.parse_args(argv)

    if args.cmd == "resolve":
        for k, v in resolve(args.shard, csv(args.flavor)).items():
            print(f"{k}={v}")
        return 0

    all_versions = matrix_versions()
    only = csv(args.only)
    for v in only:
        if v not in all_versions:
            raise SystemExit(f"'{v}' is not a version in matrix.json ({' '.join(all_versions)})")
    versions = [v for v in all_versions if not only or v in only]
    apps = args.apps == "true"
    cells = read_cells(versions) if apps else []
    shards = plan(versions, csv(args.flavor), apps, cells,
                  float(os.environ.get("EXT_SHARD_MIN") or DEFAULT_SHARD_MIN))
    if args.table:
        print("| shard | estimated minutes |\n|---|---|")
        for s in shards:
            print(f"| {s['id']} | {s['minutes']:.0f} |")
    else:
        print(json.dumps([s["id"] for s in shards]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
