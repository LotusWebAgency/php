#!/usr/bin/env python3
"""The OpenVEX source of truth (vex/php.openvex.json) and what is derived from it.

    python3 ci/vex.py check                   # schema + review deadlines, exit 1 on a problem
    python3 ci/vex.py check --warn-within 14  # CI: ::warning:: annotations, exit 1 only on a schema problem
    python3 ci/vex.py trivyignore --write     # regenerate .trivyignore
    python3 ci/vex.py trivyignore --check     # fail on drift (what preflight runs)
    python3 ci/vex.py emit --digest sha256:.. --flavor cli-builder
                                                   # the document scoped to one image, for cosign attest

One file holds every accepted-risk decision. Two things come out of it:

  * .trivyignore, which the Trivy gate in .github/workflows/ci.yml reads. Trivy's
    --vex only suppresses not_affected/fixed, and our decisions are mostly
    `affected` (accepted, no upstream fix), so the gate keeps using an ignore file
    -- generated, so it cannot disagree with the VEX file.
  * the per-image OpenVEX attestation (emit), which ci/attest-image.sh signs
    onto every published digest.

Statements in the source file name their product as the repository purl plus a
`flavor` qualifier (non-standard, source file only: it picks the images a
statement applies to and is replaced by the real image digest purl in emit).

The re-review deadline is the token `review-by: YYYY-MM-DD` inside status_notes
(OpenVEX statements are closed objects, there is no field for it). It is
exclusive, like Trivy's `exp:`: from that day on the generated .trivyignore line
has expired, so the Trivy gate itself fails on the finding again (that is the
only thing that gates a build). Nothing else does: the unit tests deliberately
do not look at the date, because tests/preflight.sh runs before every build job
and a date-triggered failure there would stop the whole publish. `check` is the
tool people and CI use to see the date coming: plain, it exits 1 once a deadline
has passed; with --warn-within N it prints GitHub ::warning:: lines for every
statement due within N days (or already due) and still exits 0.
"""
import argparse
import datetime
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VEX_PATH = ROOT / "vex" / "php.openvex.json"
TRIVYIGNORE_PATH = ROOT / ".trivyignore"
MATRIX_PATH = ROOT / "matrix.json"

CONTEXT = "https://openvex.dev/ns/v0.2.0"
STATUSES = ("not_affected", "affected", "fixed", "under_investigation")
JUSTIFICATIONS = (
    "component_not_present",
    "vulnerable_code_not_present",
    "vulnerable_code_not_in_execute_path",
    "vulnerable_code_cannot_be_controlled_by_adversary",
    "inline_mitigations_already_exist",
)
# Decisions that accept the finding, so the gate must not fail on them until
# their review date. under_investigation is deliberately not here.
IGNORED_STATUSES = ("affected", "not_affected")

DOC_KEYS = {"@context", "@id", "author", "role", "timestamp", "last_updated", "version", "tooling", "statements"}
STATEMENT_KEYS = {
    "@id", "version", "vulnerability", "timestamp", "last_updated", "products", "status",
    "supplier", "status_notes", "justification", "impact_statement", "action_statement",
    "action_statement_timestamp",
}
COMPONENT_KEYS = {"@id", "identifiers", "hashes", "subcomponents"}
SUBCOMPONENT_KEYS = {"@id", "identifiers", "hashes"}
VULN_KEYS = {"@id", "name", "description", "aliases"}

REVIEW_BY = re.compile(r"\breview-by:\s*(\d{4}-\d{2}-\d{2})\b")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$")


def load(path=VEX_PATH):
    return json.loads(Path(path).read_text())


def image_repository():
    return json.loads(MATRIX_PATH.read_text())["image"]


def oci_purl(repository, digest=None, flavor=None):
    """pkg:oci/php@sha256:..?repository_url=index.docker.io/lotuswebagency/php"""
    name = repository.rsplit("/", 1)[-1]
    purl = f"pkg:oci/{name}"
    if digest:
        purl += f"@{digest}"
    purl += f"?repository_url=index.docker.io/{repository}"
    if flavor:
        purl += f"&flavor={flavor}"
    return purl


def review_date(statement):
    m = REVIEW_BY.search(statement.get("status_notes", ""))
    if not m:
        return None
    try:
        return datetime.date.fromisoformat(m.group(1))
    except ValueError:
        return None


def validate(doc):
    """Problems as strings. Mirrors openvex_json_schema_0.2.0.json (which is strict:
    additionalProperties false on statements, products and vulnerabilities),
    plus the rules of this repo: a review deadline on every statement."""
    problems = []

    def closed(obj, allowed, where):
        for k in obj:
            if k not in allowed:
                problems.append(f"{where}: unknown key {k!r}")

    if not isinstance(doc, dict):
        return ["document is not an object"]
    closed(doc, DOC_KEYS, "document")
    for k in ("@context", "@id", "author", "timestamp", "version", "statements"):
        if k not in doc:
            problems.append(f"document: missing {k!r}")
    if doc.get("@context") != CONTEXT:
        problems.append(f"document: @context must be {CONTEXT}")
    if not isinstance(doc.get("version"), int) or doc.get("version", 0) < 1:
        problems.append("document: version must be an integer >= 1")
    if not TIMESTAMP.match(str(doc.get("timestamp", ""))):
        problems.append("document: timestamp must be an RFC 3339 date-time")
    statements = doc.get("statements")
    if not isinstance(statements, list) or not statements:
        return problems + ["document: statements must be a non-empty array (the schema's minItems is 1)"]

    seen = set()
    for i, st in enumerate(statements):
        where = f"statements[{i}]"
        if not isinstance(st, dict):
            problems.append(f"{where}: not an object")
            continue
        closed(st, STATEMENT_KEYS, where)
        vuln = st.get("vulnerability")
        if not isinstance(vuln, dict) or not vuln.get("name"):
            problems.append(f"{where}: vulnerability.name is required")
            vuln = {}
        closed(vuln, VULN_KEYS, f"{where}.vulnerability")
        where = f"{where} ({vuln.get('name', '?')})"
        status = st.get("status")
        if status not in STATUSES:
            problems.append(f"{where}: status must be one of {', '.join(STATUSES)}")
        if status == "not_affected":
            if st.get("justification") not in JUSTIFICATIONS and not st.get("impact_statement"):
                problems.append(f"{where}: not_affected needs a valid justification or an impact_statement")
            if "justification" in st and st["justification"] not in JUSTIFICATIONS:
                problems.append(f"{where}: unknown justification {st['justification']!r}")
        if status == "affected" and not st.get("action_statement"):
            problems.append(f"{where}: affected needs an action_statement")
        if not TIMESTAMP.match(str(st.get("timestamp", ""))):
            problems.append(f"{where}: timestamp is required (RFC 3339 date-time)")
        if review_date(st) is None:
            problems.append(f"{where}: status_notes must carry 'review-by: YYYY-MM-DD'")
        products = st.get("products")
        if not isinstance(products, list) or not products:
            problems.append(f"{where}: products must be a non-empty array")
            products = []
        for j, product in enumerate(products):
            pw = f"{where}.products[{j}]"
            closed(product, COMPONENT_KEYS, pw)
            if not str(product.get("@id", "")).startswith("pkg:oci/"):
                problems.append(f"{pw}: @id must be a pkg:oci purl")
            subs = product.get("subcomponents")
            if not isinstance(subs, list) or not subs:
                problems.append(f"{pw}: subcomponents must name the affected package purl(s)")
                subs = []
            for k, sub in enumerate(subs):
                closed(sub, SUBCOMPONENT_KEYS, f"{pw}.subcomponents[{k}]")
                if not str(sub.get("@id", "")).startswith("pkg:"):
                    problems.append(f"{pw}.subcomponents[{k}]: @id must be a purl")
            key = (vuln.get("name"), product.get("@id"))
            if key in seen:
                problems.append(f"{pw}: {key[0]} is already stated for {key[1]}")
            seen.add(key)
    return problems


def expired(doc, today):
    """[(vulnerability, review date)] whose deadline is today or earlier."""
    out = []
    for st in doc["statements"]:
        due = review_date(st)
        if due is not None and today >= due:
            out.append((st["vulnerability"]["name"], due))
    return out


def due_within(doc, today, days):
    """[(vulnerability, review date)] due on or before today + days, soonest first."""
    horizon = today + datetime.timedelta(days=days)
    out = [(st["vulnerability"]["name"], review_date(st)) for st in doc["statements"] if review_date(st) <= horizon]
    return sorted(out, key=lambda x: x[1])


def trivyignore(doc):
    lines = [
        "# GENERATED from vex/php.openvex.json by ci/vex.py -- do not edit.",
        "# Accepted risks for the Trivy gate in .github/workflows/ci.yml. Each line",
        "# expires on its statement's review-by date, so the gate re-asks the question.",
        "",
    ]
    by_vuln = {}
    for st in doc["statements"]:
        if st["status"] not in IGNORED_STATUSES:
            continue
        by_vuln.setdefault(st["vulnerability"]["name"], []).append(st)
    for name, sts in by_vuln.items():
        due = min(review_date(s) for s in sts)
        for s in sts:
            comps = sorted({sub["@id"] for p in s["products"] for sub in p["subcomponents"]})
            flavors = sorted({m.group(1) for p in s["products"] if (m := re.search(r"[?&]flavor=([^&]+)", p["@id"]))})
            where = f" in {', '.join(flavors)}" if flavors else ""
            lines.append(f"# {name}: {', '.join(comps)}{where} -- {s['status']}")
        lines.append(f"{name} exp:{due.isoformat()}")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def applies(product, flavor):
    m = re.search(r"[?&]flavor=([^&]+)", product["@id"])
    return m is None or m.group(1) == flavor


def emit(doc, repository, digest, flavor, now):
    """The document for one image: only the statements that apply to its flavor,
    each product swapped for the image's own digest purl. None when none apply
    (the schema has no empty document)."""
    if not DIGEST.match(digest):
        raise ValueError(f"not a sha256 digest: {digest!r}")
    purl = oci_purl(repository, digest)
    statements = []
    for st in doc["statements"]:
        subs = [sub for p in st["products"] if applies(p, flavor) for sub in p["subcomponents"]]
        if not subs:
            continue
        out = {k: v for k, v in st.items() if k != "products"}
        out["products"] = [{
            "@id": purl,
            "identifiers": {"purl": purl},
            "hashes": {"sha-256": digest.split(":", 1)[1]},
            "subcomponents": subs,
        }]
        statements.append(out)
    if not statements:
        return None
    return {
        "@context": CONTEXT,
        "@id": f"https://github.com/LotusWebAgency/php/vex/{digest.replace(':', '-')}",
        "author": doc["author"],
        "timestamp": now,
        "version": 1,
        "tooling": "ci/vex.py",
        "statements": statements,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--today", type=datetime.date.fromisoformat, default=None)
    c.add_argument("--warn-within", type=int, default=None, metavar="DAYS",
                   help="annotate deadlines within DAYS days (or past) as ::warning:: and do not fail on them")
    t = sub.add_parser("trivyignore")
    g = t.add_mutually_exclusive_group(required=True)
    g.add_argument("--write", action="store_true")
    g.add_argument("--check", action="store_true")
    e = sub.add_parser("emit")
    e.add_argument("--digest", required=True)
    e.add_argument("--flavor", required=True)
    e.add_argument("--out", default="-")
    e.add_argument("--now", default=None, help="RFC 3339 timestamp (default: now, UTC)")
    args = ap.parse_args(argv)

    doc = load()
    problems = validate(doc)
    if problems:
        print("\n".join(f"FAIL: {p}" for p in problems), file=sys.stderr)
        return 1

    if args.cmd == "check":
        today = args.today or datetime.datetime.now(datetime.timezone.utc).date()
        if args.warn_within is not None:
            soon = due_within(doc, today, args.warn_within)
            for name, due in soon:
                when = f"is due for re-review on {due}" if due > today else f"was due for re-review on {due} and the Trivy gate no longer ignores it"
                print(f"::warning title=VEX review-by::{name} {when} -- re-check upstream, then renew or remove it in vex/php.openvex.json")
            print(f"ok: {len(doc['statements'])} VEX statements valid, {len(soon)} due within {args.warn_within} days as of {today}")
            return 0
        late = expired(doc, today)
        for name, due in late:
            print(f"FAIL: {name} was due for re-review on {due} -- re-check upstream, then renew or remove it", file=sys.stderr)
        if late:
            return 1
        print(f"ok: {len(doc['statements'])} VEX statements valid, none past review-by as of {today}")
        return 0

    if args.cmd == "trivyignore":
        want = trivyignore(doc)
        if args.write:
            TRIVYIGNORE_PATH.write_text(want)
            return 0
        have = TRIVYIGNORE_PATH.read_text() if TRIVYIGNORE_PATH.exists() else ""
        if have != want:
            print("FAIL: .trivyignore is stale -- run: python3 ci/vex.py trivyignore --write", file=sys.stderr)
            return 1
        print("ok: .trivyignore matches vex/php.openvex.json")
        return 0

    now = args.now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        out = emit(doc, image_repository(), args.digest, args.flavor, now)
    except ValueError as err:
        print(f"FAIL: {err}", file=sys.stderr)
        return 1
    if out is None:
        print(f"no VEX statement applies to flavor {args.flavor}", file=sys.stderr)
        return 3
    text = json.dumps(out, indent=2) + "\n"
    if args.out == "-":
        sys.stdout.write(text)
    else:
        Path(args.out).write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
