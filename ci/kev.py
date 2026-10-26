#!/usr/bin/env python3
"""Fail when a Trivy report names a vulnerability in CISA's Known Exploited Vulnerabilities catalog.

    python3 ci/kev.py REPORT.json --catalog known_exploited_vulnerabilities.json

REPORT.json is `trivy image --format json` output, scanned with every severity and
unfixed findings included (a KEV entry without a fix must still fail). The catalog is
the file CISA publishes at
https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json;
the CI prepare job fetches it once per run so every matrix leg checks one snapshot.

Trivy applies .trivyignore before it writes the report, so a finding accepted in
vex/php.openvex.json stays accepted here too.

Exit status: 0 no finding is in the catalog, 1 at least one is (each is printed),
2 the report or the catalog is unreadable or malformed. A malformed catalog never
passes silently.
"""
import argparse
import json
import sys
from pathlib import Path


class InputError(Exception):
    pass


def load_json(path, what):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise InputError(f"{what} {path}: {exc}") from exc


def catalog_index(catalog):
    """({CVE id: entry}, catalogVersion), or InputError for anything but a usable catalog."""
    if not isinstance(catalog, dict):
        raise InputError("catalog is not a JSON object")
    version = catalog.get("catalogVersion")
    if not isinstance(version, str) or not version:
        raise InputError("catalog has no catalogVersion")
    entries = catalog.get("vulnerabilities")
    if not isinstance(entries, list) or not entries:
        raise InputError("catalog has no vulnerabilities list")
    index = {}
    for position, entry in enumerate(entries):
        cve = entry.get("cveID") if isinstance(entry, dict) else None
        if not isinstance(cve, str) or not cve:
            raise InputError(f"catalog vulnerabilities[{position}] has no cveID")
        index[cve] = entry
    return index, version


def findings(report):
    """Every vulnerability in a Trivy JSON report; Results may be absent or null."""
    if not isinstance(report, dict):
        raise InputError("report is not a JSON object")
    results = report.get("Results")
    if results is None:
        return
    if not isinstance(results, list):
        raise InputError("report Results is not a list")
    for result in results:
        if not isinstance(result, dict):
            raise InputError("report Results entry is not an object")
        vulns = result.get("Vulnerabilities")
        if vulns is None:
            continue
        if not isinstance(vulns, list):
            raise InputError("report Vulnerabilities is not a list")
        for vuln in vulns:
            if not isinstance(vuln, dict) or not isinstance(vuln.get("VulnerabilityID"), str):
                raise InputError("report vulnerability has no VulnerabilityID")
            yield vuln


def matches(report, index):
    """[(trivy finding, catalog entry)] in report order."""
    return [(vuln, index[vuln["VulnerabilityID"]]) for vuln in findings(report) if vuln["VulnerabilityID"] in index]


def describe(vuln, entry):
    return (
        f"{vuln['VulnerabilityID']}  {vuln.get('PkgName', '?')} {vuln.get('InstalledVersion', '?')}"
        f"  fixed: {vuln.get('FixedVersion') or 'no fix'}"
        f"  KEV added {entry.get('dateAdded', '?')}"
        f"  ransomware use: {entry.get('knownRansomwareCampaignUse', '?')}"
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("report", help="Trivy JSON report")
    parser.add_argument("--catalog", required=True, help="CISA KEV catalog JSON")
    args = parser.parse_args(argv)
    try:
        index, version = catalog_index(load_json(args.catalog, "catalog"))
        hits = matches(load_json(args.report, "report"), index)
    except InputError as exc:
        print(f"kev: {exc}", file=sys.stderr)
        return 2
    print(f"KEV catalog {version}: {len(index)} entries")
    if not hits:
        print("no finding is in the catalog")
        return 0
    for vuln, entry in hits:
        print(f"KEV: {describe(vuln, entry)}")
    print(f"{len(hits)} finding(s) in the Known Exploited Vulnerabilities catalog", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
