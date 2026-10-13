#!/usr/bin/env python3
"""Derive PGO corpus tier membership from matrix.json.

A corpus is built once per *tier* and reused by every PHP version in it, so the
frameworks it installs must run on the oldest version in the tier: Composer
bakes the resolved floor into vendor/composer/platform_check.php, which
autoload.php requires before any application code, and WordPress refuses to
boot below its own $required_php_version. A corpus resolved above its tier's
floor fatals at autoload on every lower version, which a training run cannot
tell apart from a slow page.

php/pgo/corpus/tiers lists only floors. A version belongs to the tier with the
greatest floor that is <= it. The release to resolve Composer against, the
builder image and the image tag come from matrix.json. A new PHP version above
the top floor joins that tier without an edit here; one below every floor makes
`check` fail.

    pgo_tiers.py list                  one row per tier
    pgo_tiers.py field <floor> <name>  release | builder | tag | versions
    pgo_tiers.py tier-of <version>     the floor that serves that version
    pgo_tiers.py apps-of <floor>       the apps that tier trains, one per line
    pgo_tiers.py check                 exit 1 unless every pgo version has a tier
                                       and every opt-out records a reason
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MATRIX = ROOT / "matrix.json"
TIERS = ROOT / "php" / "pgo" / "corpus" / "tiers"
REGISTRY = "ghcr.io/lotuswebagency/php/corpus"


def key(version):
    return tuple(int(part) for part in version.split("."))


def tier_lines():
    """(floor, [apps]) per data line of corpus/tiers, in file order."""
    out = []
    for line in TIERS.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        out.append((fields[0], fields[1:]))
    return out


def floors():
    out = [floor for floor, _apps in tier_lines()]
    if not out:
        sys.exit("no tier floors in %s" % TIERS)
    return sorted(out, key=key, reverse=True)


def apps_of(floor):
    for known, apps in tier_lines():
        if known == floor:
            return apps
    return None


def matrix():
    return json.loads(MATRIX.read_text())


def tier_of(version, known=None):
    for floor in known if known is not None else floors():
        if key(floor) <= key(version):
            return floor
    return None


def table():
    m = matrix()
    known = floors()
    rows = {}
    for floor in known:
        if floor not in m["versions"]:
            sys.exit("tier floor %s is not a version in matrix.json" % floor)
        rows[floor] = {
            "release": m["versions"][floor]["release"],
            "builder": "%s:%s-cli-builder" % (m["image"], floor),
            "tag": "%s:php%s" % (REGISTRY, floor),
            "versions": [],
        }
    for version, spec in sorted(m["versions"].items(), key=lambda kv: key(kv[0])):
        if not spec.get("pgo"):
            continue
        floor = tier_of(version, known)
        if floor is None:
            continue
        rows[floor]["versions"].append(version)
    return m, known, rows


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    m, known, rows = table()

    if cmd == "list":
        for floor in sorted(known, key=key, reverse=True):
            r = rows[floor]
            print("\t".join([floor, r["release"], r["builder"], r["tag"], ",".join(r["versions"])]))
        return 0

    if cmd == "field":
        floor, name = argv[2], argv[3]
        if floor not in rows:
            sys.exit("no such tier: %s" % floor)
        value = rows[floor][name]
        print(",".join(value) if isinstance(value, list) else value)
        return 0

    # The highest matrix version strictly below a floor: the negative control
    # that tier's corpus must fail on, proving the harness can fail at all.
    if cmd == "control-of":
        floor = argv[2]
        below = [v for v in m["versions"] if key(v) < key(floor)]
        if below:
            print(max(below, key=key))
        return 0

    if cmd == "apps-of":
        apps = apps_of(argv[2])
        if apps is None:
            sys.exit("no such tier: %s" % argv[2])
        print("\n".join(apps))
        return 0

    if cmd == "tier-of":
        floor = tier_of(argv[2], known)
        if floor is None:
            sys.exit("no tier serves php %s" % argv[2])
        print(floor)
        return 0

    if cmd == "check":
        problems = []
        for version, spec in sorted(m["versions"].items(), key=lambda kv: key(kv[0])):
            if not spec.get("pgo"):
                # An opt-out must say why: a bare "pgo": false is
                # indistinguishable from a typo.
                reason = spec.get("pgo_disabled_reason", "").strip()
                if not reason:
                    problems.append(
                        "php %s sets pgo false with no pgo_disabled_reason in matrix.json" % version
                    )
                else:
                    print("ok: php %s opts out of pgo -- %s" % (version, reason))
                continue
            floor = tier_of(version, known)
            if floor is None:
                problems.append(
                    "php %s has pgo enabled but no corpus tier covers it "
                    "(lowest floor is %s) -- add a tier or set pgo false with a reason"
                    % (version, min(known, key=key))
                )
        seen = set()
        for floor, apps in tier_lines():
            if floor in seen:
                problems.append("tier %s is declared twice in corpus/tiers" % floor)
            seen.add(floor)
            if not apps:
                problems.append("tier %s names no apps in corpus/tiers" % floor)
            for app in apps:
                if not (ROOT / "php" / "pgo" / "corpus" / app / "endpoints").is_file():
                    problems.append("tier %s names app %s, which has no corpus/%s/endpoints" % (floor, app, app))
        for floor in known:
            if not rows[floor]["versions"]:
                problems.append("tier %s serves no pgo version -- delete it or fix matrix.json" % floor)
        for problem in problems:
            print("FAIL: %s" % problem, file=sys.stderr)
        if problems:
            return 1
        for floor in sorted(known, key=key, reverse=True):
            print("ok: tier %s serves php %s" % (floor, " ".join(rows[floor]["versions"])))
        return 0

    sys.exit("unknown command: %s" % cmd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
