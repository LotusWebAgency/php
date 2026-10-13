#!/usr/bin/env python3
"""The signed test-result predicate attached to every published digest.

    python3 ci/result_predicate.py platform ... --trivy-outcome success --trivy-severity CRITICAL,HIGH --out amd64.test-result.json
    python3 ci/result_predicate.py aggregate amd64.json arm64.json --out list.json

`platform` runs in the build job once smoke and the Trivy gate have passed
against the pushed digest, and refuses to write anything if the captured smoke
log does not show a passing run. `aggregate` merges the per-architecture files
into the one that goes on the multi-arch manifest list. ci/attest-image.sh
signs the results with cosign (in-toto predicate type PREDICATE_TYPE).
"""
import argparse
import datetime
import hashlib
import json
import re
import sys
from pathlib import Path

PREDICATE_TYPE = "https://github.com/LotusWebAgency/php/attestation/test-result/v1"
# Rekor refuses attestations over 100 KB; stay well inside.
MAX_BYTES = 90_000
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
OK_LINE = re.compile(r"^ok: (.+?)\s*$")
FAIL_LINE = re.compile(r"^FAIL\b")

# Fields shared by every platform of one image; aggregate refuses a mix.
COMMON = ("repository", "php_version", "flavor", "uarch", "inputs_hash", "git_sha", "git_ref", "workflow_run_url")


def sha256_file(path):
    return "sha256:" + hashlib.sha256(Path(path).read_bytes()).hexdigest()


def smoke_result(log_path):
    """The verdict from smoke.sh's captured output, or ValueError.
    smoke.sh ends with SMOKE PASSED only when every check passed, and prints
    FAIL: before exiting non-zero; both are required, not just the exit code
    the caller already had."""
    lines = Path(log_path).read_text(errors="replace").splitlines()
    fails = [ln for ln in lines if FAIL_LINE.match(ln)]
    if fails:
        raise ValueError(f"{log_path}: smoke output has a failure: {fails[0]}")
    if not any(ln.strip() == "SMOKE PASSED" for ln in lines):
        raise ValueError(f"{log_path}: no 'SMOKE PASSED' line -- the run did not finish")
    checks = [m.group(1) for ln in lines if (m := OK_LINE.match(ln))]
    if not checks:
        raise ValueError(f"{log_path}: no 'ok:' lines captured")
    return {"verdict": "pass", "script": "tests/smoke.sh", "check_count": len(checks), "passed_checks": checks}


def trivy_info(path):
    """{version, db_updated_at} from `trivy --version --format json`, whatever of it
    is there. Best effort: the scan itself is gated by the Trivy step, this only
    says which scanner and database produced the verdict."""
    out = {}
    if not path or not Path(path).is_file():
        return out
    try:
        info = json.loads(Path(path).read_text())
    except ValueError:
        return out
    if isinstance(info, dict):
        if info.get("Version"):
            out["version"] = info["Version"]
        db = info.get("VulnerabilityDB")
        if isinstance(db, dict) and db.get("UpdatedAt"):
            out["db_updated_at"] = db["UpdatedAt"]
    return out


def trivy_result(args):
    """The verdict is the outcome GitHub recorded for the Trivy step, not a constant:
    anything but `success` (failure, cancelled, skipped) refuses the predicate."""
    if args.trivy_outcome != "success":
        raise ValueError(f"the Trivy step's outcome is {args.trivy_outcome!r}, not 'success' -- not recording a pass")
    return {
        "verdict": "pass",
        "severity": args.trivy_severity,
        "ignore_unfixed": True,
        **trivy_info(args.trivy_info),
        "ignorefile_sha256": sha256_file(args.trivyignore),
        "vex_sha256": sha256_file(args.vex),
    }


def platform_predicate(args, now):
    if not DIGEST.match(args.image_digest):
        raise ValueError(f"not a sha256 digest: {args.image_digest!r}")
    return {
        "repository": args.repository,
        "php_version": args.php,
        "flavor": args.flavor,
        "uarch": args.uarch,
        "inputs_hash": args.inputs_hash,
        "git_sha": args.git_sha,
        "git_ref": args.git_ref,
        "workflow_run_url": args.run_url,
        "created": now,
        "platforms": [{
            "arch": args.arch,
            "image_digest": args.image_digest,
            "smoke": smoke_result(args.smoke_log),
            "trivy": trivy_result(args),
        }],
    }


def aggregate(preds):
    if not preds:
        raise ValueError("nothing to aggregate")
    first = preds[0]
    for p in preds[1:]:
        for k in COMMON:
            if p.get(k) != first.get(k):
                raise ValueError(f"platform results disagree on {k}: {first.get(k)!r} vs {p.get(k)!r}")
    arches = [pl["arch"] for p in preds for pl in p["platforms"]]
    if len(arches) != len(set(arches)):
        raise ValueError(f"duplicate architecture in {arches}")
    out = {k: first[k] for k in COMMON}
    out["created"] = max(p["created"] for p in preds)
    out["platforms"] = sorted((pl for p in preds for pl in p["platforms"]), key=lambda pl: pl["arch"])
    return out


def write(pred, out):
    text = json.dumps(pred, indent=2) + "\n"
    if len(text.encode()) > MAX_BYTES:
        raise ValueError(f"predicate is {len(text.encode())} bytes, over the {MAX_BYTES} budget")
    Path(out).write_text(text)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("platform")
    p.add_argument("--repository", required=True)
    p.add_argument("--php", required=True)
    p.add_argument("--flavor", required=True)
    p.add_argument("--uarch", required=True)
    p.add_argument("--arch", required=True)
    p.add_argument("--image-digest", required=True, help="the platform image manifest that was tested")
    p.add_argument("--inputs-hash", required=True)
    p.add_argument("--git-sha", required=True)
    p.add_argument("--git-ref", required=True)
    p.add_argument("--run-url", required=True)
    p.add_argument("--smoke-log", required=True)
    p.add_argument("--trivy-outcome", required=True, help="steps.<id>.outcome of the Trivy gate step; only 'success' is accepted")
    p.add_argument("--trivy-severity", required=True, help="the severity list the gate ran with")
    p.add_argument("--trivy-info", default=None, help="JSON from `trivy --version --format json` (optional)")
    p.add_argument("--trivyignore", default=".trivyignore")
    p.add_argument("--vex", default="vex/php.openvex.json")
    p.add_argument("--now", default=None)
    p.add_argument("--out", required=True)
    a = sub.add_parser("aggregate")
    a.add_argument("files", nargs="+")
    a.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "platform":
            now = args.now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            write(platform_predicate(args, now), args.out)
        else:
            write(aggregate([json.loads(Path(f).read_text()) for f in args.files]), args.out)
    except ValueError as err:
        print(f"FAIL: {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
