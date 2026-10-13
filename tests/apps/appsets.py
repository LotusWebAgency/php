#!/usr/bin/env python3
"""The cells of the application test matrix, from tests/apps/sets.

Every consumer (lib.sh, run.sh, run-matrix.sh, build-fixture.sh through lib.sh,
tests/extended.sh, ci/extended-*.sh) asks this one script, so the rules for
which image runs which app release live here and in `sets`, nowhere else.

  appsets.py check
  appsets.py apps                                       app names, file order
  appsets.py rows   [--app A]                           "app set php-min php-max"
  appsets.py field  <app> <set> min|max|db
  appsets.py sets   [--app A] [--php V,..]              "app set" fixtures those PHP versions need
  appsets.py cells  [--app A].. [--php V,..] [--flavor F,..] [--variant baseline|v3] [--stock]
                                                        "app set php flavor variant configs"

A cell is (app, set, php, flavor, variant): one app release on one image. Its
configs are the fpm configs it runs (default, hardened); the other flavors run
one, default. --stock plans for the stock baseline images: baseline variant,
default config, and no hardened (the stock images have no snuffleupagus).

Standard library only. Exits 1 with a message on stderr on any error.
"""

import argparse
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(ROOT, "..", ".."))

# Flavors that run application suites. ext-builder is a flavor of the matrix
# but has no suites (it has its own test, tests/test-ext-builder.sh).
APP_FLAVORS = ("fpm", "cli", "cli-builder")
FLAGS = ("builder", "v3", "hardened")
DATABASES = ("mariadb",)
VARIANTS = ("baseline", "v3")


class SetsError(Exception):
    pass


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def load_matrix():
    with open(os.path.join(REPO, "matrix.json")) as fh:
        return json.load(fh)


def versions(matrix):
    return sorted(matrix["versions"], key=vkey)


def hardened_floor(ext_path=None):
    """The first PHP version snuffleupagus ships on, from php/ext.json."""
    with open(ext_path or os.path.join(REPO, "php", "ext.json")) as fh:
        reg = json.load(fh)
    for ext in reg["extensions"] if isinstance(reg, dict) else reg:
        if ext.get("name") == "snuffleupagus":
            m = re.fullmatch(r">=(\d+\.\d+)", ext.get("php", ""))
            if not m:
                raise SetsError("php/ext.json: snuffleupagus has no '>=X.Y' php constraint")
            return m.group(1)
    raise SetsError("php/ext.json has no snuffleupagus entry")


class Row:
    def __init__(self, app, set_, php, flags, db, line):
        self.app, self.set, self.php, self.flags, self.db, self.line = app, set_, php, flags, db, line

    @property
    def lo(self):
        return self.php[0]

    @property
    def hi(self):
        return self.php[-1]


def expand_php(token, all_versions, where):
    """'7.2,7.4-8.0' -> ['7.2', '7.4', '8.0'], sorted, validated against matrix.json."""
    out = []
    for part in token.split(","):
        m = re.fullmatch(r"(\d+\.\d+)(?:-(\d+\.\d+))?", part)
        if not m:
            raise SetsError(f"{where}: '{part}' is not a PHP version or a range X.Y-X.Y")
        lo, hi = m.group(1), m.group(2) or m.group(1)
        for v in (lo, hi):
            if v not in all_versions:
                raise SetsError(f"{where}: PHP {v} is not a version in matrix.json ({' '.join(all_versions)})")
        if vkey(lo) > vkey(hi):
            raise SetsError(f"{where}: range {part} runs backwards")
        out += [v for v in all_versions if vkey(lo) <= vkey(v) <= vkey(hi)]
    dupes = sorted({v for v in out if out.count(v) > 1}, key=vkey)
    if dupes:
        raise SetsError(f"{where}: PHP {', '.join(dupes)} listed twice")
    return sorted(out, key=vkey)


def load_rows(matrix=None, path=None):
    matrix = matrix or load_matrix()
    all_versions = versions(matrix)
    rows, seen = [], {}
    with open(path or os.path.join(ROOT, "sets")) as fh:
        for n, raw in enumerate(fh, 1):
            text = raw.split("#", 1)[0].strip()
            if not text:
                continue
            where = f"tests/apps/sets:{n}"
            cols = text.split()
            if len(cols) != 5:
                raise SetsError(f"{where}: want 5 columns (app set php flags db), got {len(cols)}")
            app, set_, php, flags, db = cols
            if not re.fullmatch(r"[a-z][a-z0-9]*", app):
                raise SetsError(f"{where}: app '{app}' is not a lowercase name")
            if not re.fullmatch(r"[a-z0-9][a-z0-9.]*", set_):
                raise SetsError(f"{where}: set '{set_}' is not a lowercase fixture tag and compose project name ([a-z0-9.])")
            if (app, set_) in seen:
                raise SetsError(f"{where}: {app} {set_} is already a row (line {seen[(app, set_)]}); a fixture is one row")
            seen[(app, set_)] = n
            flag_list = [] if flags == "-" else flags.split(",")
            for f in flag_list:
                if f not in FLAGS:
                    raise SetsError(f"{where}: flag '{f}' is not one of {', '.join(FLAGS)} (or - for none)")
            if len(set(flag_list)) != len(flag_list):
                raise SetsError(f"{where}: a flag is listed twice in '{flags}'")
            if db not in DATABASES:
                raise SetsError(f"{where}: database '{db}' is not one of {', '.join(DATABASES)}")
            php_list = expand_php(php, all_versions, where)
            if "v3" in flag_list and not any(has_v3(matrix, v) for v in php_list):
                raise SetsError(f"{where}: flag v3 does nothing: none of {','.join(php_list)} has a v3 image")
            rows.append(Row(app, set_, php_list, flag_list, db, n))
    return rows


def has_v3(matrix, php):
    return "v3" in matrix["versions"][php].get("uarch", [])


def require_apps(rows, apps):
    """An --app filter naming no app in `sets` is a typo, not an empty plan."""
    known = list(dict.fromkeys(r.app for r in rows))
    for app in apps:
        if app not in known:
            raise SetsError(f"app '{app}' is not in tests/apps/sets ({' '.join(known)})")


def cells(rows, matrix, apps=(), php=(), flavors=(), variant="", stock=False, ext_path=None):
    floor = hardened_floor(ext_path)
    out = []
    for row in rows:
        if apps and row.app not in apps:
            continue
        for v in row.php:
            if php and v not in php:
                continue
            row_flavors = ["fpm", "cli"] + (["cli-builder"] if "builder" in row.flags else [])
            for flavor in row_flavors:
                if flavors and flavor not in flavors:
                    continue
                variants = ["baseline"] + (["v3"] if "v3" in row.flags and has_v3(matrix, v) else [])
                for var in variants:
                    if variant and var != variant:
                        continue
                    if stock and var != "baseline":
                        continue
                    configs = ["default"]
                    if flavor == "fpm" and "hardened" in row.flags and vkey(v) >= vkey(floor) and not stock:
                        configs.append("hardened")
                    out.append((row.app, row.set, v, flavor, var, ",".join(configs)))
    return out


def lock_has_rows(app, set_):
    with open(os.path.join(ROOT, "apps.lock")) as fh:
        for raw in fh:
            cols = raw.split()
            if len(cols) < 2 or cols[0].startswith("#"):
                continue
            if cols[1] == set_ and (cols[0] == app or cols[0].startswith(app + "-")):
                return True
    return False


def check_known_failures(rows, path=None):
    """Every tests/apps/known-failures row names a cell of `sets`, a check and a why."""
    path = path or os.path.join(ROOT, "known-failures")
    if not os.path.exists(path):
        return 0
    by_set = {(r.app, r.set): r for r in rows}
    seen = set()
    with open(path) as fh:
        for n, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            where = f"tests/apps/known-failures:{n}"
            cols = line.split(None, 3)
            if len(cols) < 4 or " -- " not in " " + cols[3]:
                raise SetsError(f"{where}: want 'app set php check -- why'")
            app, set_, php, rest = cols
            name, _, why = rest.partition(" -- ")
            name, why = name.strip(), why.strip()
            if not name or not why:
                raise SetsError(f"{where}: both the check name and the why are required")
            row = by_set.get((app, set_))
            if row is None:
                raise SetsError(f"{where}: no {app} set '{set_}' in tests/apps/sets")
            if php not in row.php:
                raise SetsError(f"{where}: {app} {set_} is not tested on {php} (sets has {','.join(row.php)})")
            if (app, set_, php, name) in seen:
                raise SetsError(f"{where}: duplicate row")
            seen.add((app, set_, php, name))
    return len(seen)


def check(rows, matrix):
    if not rows:
        raise SetsError("tests/apps/sets has no rows")
    for row in rows:
        where = f"tests/apps/sets:{row.line} ({row.app} {row.set})"
        if not os.path.isfile(os.path.join(ROOT, row.app, "fixture", "build.sh")):
            raise SetsError(f"{where}: no fixture recipe at tests/apps/{row.app}/fixture/build.sh")
        if not os.path.isdir(os.path.join(ROOT, row.app, "suite")):
            raise SetsError(f"{where}: no suites at tests/apps/{row.app}/suite")
        if not lock_has_rows(row.app, row.set):
            raise SetsError(f"{where}: tests/apps/apps.lock has no row for {row.app} set {row.set}")
        # Duplicate cells cannot survive the one-row-per-fixture and
        # no-repeated-version rules above; assert it anyway, it is cheap.
        listed = cells([row], matrix)
        if len(listed) != len(set(listed)):
            raise SetsError(f"{where}: duplicate cells")
    hardened_floor()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    sub.add_parser("apps")
    p = sub.add_parser("rows")
    p.add_argument("--app")
    p = sub.add_parser("field")
    p.add_argument("app")
    p.add_argument("set")
    p.add_argument("name", choices=("min", "max", "db"))
    p = sub.add_parser("sets")
    p.add_argument("--app", action="append", default=[])
    p.add_argument("--php", default="")
    p = sub.add_parser("cells")
    p.add_argument("--app", action="append", default=[])
    p.add_argument("--php", default="")
    p.add_argument("--flavor", default="")
    p.add_argument("--variant", default="", choices=("",) + VARIANTS)
    p.add_argument("--stock", action="store_true")
    args = ap.parse_args()

    def csv(s):
        return [x for x in s.split(",") if x]

    try:
        matrix = load_matrix()
        rows = load_rows(matrix)
        if args.cmd == "check":
            check(rows, matrix)
            known = check_known_failures(rows)
            print(f"ok: tests/apps/sets: {len(rows)} sets, {len(cells(rows, matrix))} baseline and v3 cells, {known} known failures")
        elif args.cmd == "apps":
            print("\n".join(dict.fromkeys(r.app for r in rows)))
        elif args.cmd == "rows":
            require_apps(rows, [args.app] if args.app else [])
            for r in rows:
                if not args.app or r.app == args.app:
                    print(r.app, r.set, r.lo, r.hi)
        elif args.cmd == "field":
            for r in rows:
                if r.app == args.app and r.set == args.set:
                    print({"min": r.lo, "max": r.hi, "db": r.db}[args.name])
                    return 0
            raise SetsError(f"no {args.app} set '{args.set}' in tests/apps/sets")
        elif args.cmd == "sets":
            require_apps(rows, args.app)
            want = csv(args.php)
            for v in want:
                if v not in matrix["versions"]:
                    raise SetsError(f"'{v}' is not a version in matrix.json")
            for r in rows:
                if (not args.app or r.app in args.app) and (not want or set(want) & set(r.php)):
                    print(r.app, r.set)
        elif args.cmd == "cells":
            require_apps(rows, args.app)
            for flavor in csv(args.flavor):
                if flavor not in matrix["flavors"]:
                    raise SetsError(f"'{flavor}' is not a flavor in matrix.json")
            for c in cells(rows, matrix, args.app, csv(args.php), csv(args.flavor), args.variant, args.stock):
                print("\t".join(c))
    except SetsError as e:
        print(f"FAIL: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
