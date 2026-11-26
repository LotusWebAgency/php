#!/usr/bin/env python3
"""Reuse the last develop build when nothing it was built from has changed.

    python3 ci/reuse_plan.py plan --repo OWNER/REPO --event E --ref REF --rebuild BOOL --inputs-hash H \
        --targets TARGETS.json --dev-repo REPO --run-id ID --save-candidate FILE > decision.json
    python3 ci/reuse_plan.py entry --candidate FILE --entry ENTRY.json --digests-out FILE > created.json

`plan` runs in the `plan` job and answers one question: may this run test the images the newest
green develop run already built, instead of building them again? A commit that changes only
tests/, ci/ or the docs has the inputs hash of its parent (scripts/inputs-hash.sh covers exactly
the build context), so its images would be byte-for-byte what is already on php/dev.

Reuse needs every one of these, on develop push or dispatch (a pull request, main and the weekly
rebuild always build, and so does a dispatch with `rebuild`):
  - the newest run of ci.yml that is a develop push, completed with the conclusion `success` for
    the run as a whole: a run whose preflight failed can still have uploaded a candidate, and
    its images are not a release candidate. This run itself is not a candidate;
  - an unexpired `release-candidate` artifact on that run (ci/candidate.py), written for that
    run's commit, naming this tree's inputs hash, the dev repository, and every target of this
    run's matrix on both architectures and nothing else;
  - the oldest `created` in it at most five days old, so the base layers and Wolfi packages of a
    reused image are never much older than a rebuild would have taken.
Anything else, including any failure to read GitHub, is `build`, with the reason in the output:
the decision never fails the run.

`entry` runs in each `images` job of a reuse run: the {"<target>": "<repo>@sha256:<index>"} map
ci/test-images.sh --mode digest takes, for this entry's targets and architecture, from the
candidate `plan` verified, and the `created` and `built_run` the new candidate record keeps.
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

ARCHES = ("amd64", "arm64")
ARTIFACT = "release-candidate"
CANDIDATE_FILE = "release-candidate.json"
SCHEMA = 1
MAX_AGE = timedelta(days=5)
DEVELOP = "refs/heads/develop"
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TIME_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
HERE = Path(__file__).resolve().parent


class NoReuse(Exception):
    """The reason this run must build."""


class ReuseError(ValueError):
    pass


def parse_time(text, what):
    try:
        return datetime.strptime(text, TIME_FORMAT).replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        raise NoReuse(f"{what} '{text}' is not a UTC timestamp") from None


def newest_green_run(runs_doc, current_run_id):
    """The newest completed, successful develop push run of ci.yml other than this one."""
    green = [
        r for r in runs_doc.get("workflow_runs", [])
        if r.get("id") != current_run_id
        and r.get("event") == "push"
        and r.get("head_branch") == "develop"
        and r.get("path", "").endswith("/ci.yml")
        and r.get("status") == "completed"
        and r.get("conclusion") == "success"
    ]
    if not green:
        raise NoReuse("no successful develop push run of ci.yml to reuse")
    return max(green, key=lambda r: r["created_at"])


def candidate_artifact(artifacts_doc, run_id):
    found = [a for a in artifacts_doc.get("artifacts", []) if a.get("name") == ARTIFACT]
    if not found:
        raise NoReuse(f"run {run_id} left no {ARTIFACT} artifact")
    live = [a for a in found if not a.get("expired")]
    if not live:
        raise NoReuse(f"the {ARTIFACT} artifact of run {run_id} has expired")
    return max(live, key=lambda a: a["created_at"])


def check_candidate(cand, run, inputs_hash, targets, dev_repo, now, max_age):
    """The oldest `created` of a candidate that may be reused, or NoReuse."""
    if cand.get("schema") != SCHEMA:
        raise NoReuse(f"candidate schema {cand.get('schema')} is not {SCHEMA}")
    if cand.get("sha") != run["head_sha"]:
        raise NoReuse(f"candidate names commit {str(cand.get('sha'))[:12]}, run {run['id']} is {run['head_sha'][:12]}")
    if cand.get("inputs_hash") != inputs_hash:
        raise NoReuse(f"inputs hash changed: {str(cand.get('inputs_hash'))[:12]} -> {inputs_hash[:12]}")
    if cand.get("repository") != dev_repo:
        raise NoReuse(f"candidate images are in {cand.get('repository')}, not {dev_repo}")
    wanted = {t["name"]: t["tags"][0].split(":", 1)[1] for t in targets}
    have = cand.get("targets") or {}
    problems = [f"{name} is not a target of this matrix" for name in have if name not in wanted]
    created = []
    for name, tag in wanted.items():
        found = have.get(name)
        if not found:
            problems.append(f"{name} is missing")
            continue
        if found.get("tag") != tag:
            problems.append(f"{name} has tag {found.get('tag')}, expected {tag}")
        for arch in ARCHES:
            slot = (found.get("archs") or {}).get(arch)
            if not slot:
                problems.append(f"{name} {arch} is missing")
                continue
            if not all(isinstance(slot.get(k), str) and DIGEST.match(slot[k]) for k in ("index", "platform")):
                problems.append(f"{name} {arch} has no valid digests")
                continue
            created.append(parse_time(slot.get("created"), f"{name} {arch} created"))
    if problems:
        raise NoReuse("candidate does not cover this matrix: " + "; ".join(problems[:6]) + ("; ..." if len(problems) > 6 else ""))
    oldest = min(created)
    age = now - oldest
    if age > max_age:
        raise NoReuse(f"the oldest image was built {oldest.strftime(TIME_FORMAT)}, {age.total_seconds() / 86400:.1f} days ago (limit {max_age.days})")
    return oldest


def decide(api, *, event, ref, rebuild, inputs_hash, targets, dev_repo, run_id, now, max_age=MAX_AGE):
    """{"mode": "reuse"|"build", "reason", and for reuse "run_id", "built_run", "candidate"}."""
    try:
        if event not in ("push", "workflow_dispatch") or ref != DEVELOP:
            raise NoReuse(f"{event} on {ref} always builds; only develop push and dispatch reuse")
        if event == "workflow_dispatch" and rebuild:
            raise NoReuse("a rebuild was requested")
        run = newest_green_run(api.runs(), run_id)
        artifact = candidate_artifact(api.artifacts(run["id"]), run["id"])
        cand = api.candidate(artifact["id"])
        oldest = check_candidate(cand, run, inputs_hash, targets, dev_repo, now, max_age)
    except NoReuse as exc:
        return {"mode": "build", "reason": str(exc)}
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        return {"mode": "build", "reason": f"unexpected shape of the GitHub data ({type(exc).__name__}: {exc})"}
    return {
        "mode": "reuse",
        "reason": f"run {run['id']} ({run['head_sha'][:12]}) built these inputs; its oldest image is from {oldest.strftime(TIME_FORMAT)}",
        "run_id": str(run["id"]),
        "built_run": str(cand.get("built_run") or cand["run_id"]),
        "candidate": cand,
    }


class GhApi:
    """The three GitHub calls `decide` makes, through gh (GH_TOKEN) under ci/retry.sh."""

    def __init__(self, repo, run=subprocess.run):
        self.repo = repo
        self.run = run

    def _get(self, path):
        env = {**os.environ, "RETRY_KIND": "http", "RETRY_ATTEMPTS": "3", "RETRY_DELAYS": "5 15"}
        try:
            done = self.run([str(HERE / "retry.sh"), "gh", "api", path], capture_output=True, env=env, check=True, timeout=300)
        except (subprocess.SubprocessError, OSError) as exc:
            detail = getattr(exc, "stderr", b"") or b""
            raise NoReuse(f"GitHub API {path} failed: {detail.decode(errors='replace').strip() or exc}") from None
        return done.stdout

    def _json(self, path):
        try:
            return json.loads(self._get(path))
        except json.JSONDecodeError:
            raise NoReuse(f"GitHub API {path} did not return JSON") from None

    def runs(self):
        return self._json(f"repos/{self.repo}/actions/workflows/ci.yml/runs?branch=develop&event=push&status=success&per_page=20")

    def artifacts(self, run_id):
        return self._json(f"repos/{self.repo}/actions/runs/{run_id}/artifacts?name={ARTIFACT}&per_page=20")

    def candidate(self, artifact_id):
        try:
            with zipfile.ZipFile(io.BytesIO(self._get(f"repos/{self.repo}/actions/artifacts/{artifact_id}/zip"))) as z:
                return json.loads(z.read(CANDIDATE_FILE))
        except (zipfile.BadZipFile, KeyError, json.JSONDecodeError):
            raise NoReuse(f"artifact {artifact_id} does not hold a readable {CANDIDATE_FILE}") from None


def entry_digests(cand, entry):
    """For one images entry of a reuse run: the digest map, the oldest created and the build run."""
    arch = entry["arch"]
    digests, created, built = {}, [], set()
    for target in entry["targets"]:
        name = target["name"]
        slot = ((cand.get("targets") or {}).get(name) or {}).get("archs", {}).get(arch)
        if not slot:
            raise ReuseError(f"the candidate has no {name} {arch}")
        digests[name] = f"{cand['repository']}@{slot['index']}"
        created.append(slot["created"])
        built.add(str(slot.get("built_run") or cand.get("built_run") or cand["run_id"]))
    if len(built) != 1:
        raise ReuseError(f"entry {entry['name']} spans more than one build run: {sorted(built)}")
    return {"digests": digests, "created": min(created), "built_run": built.pop()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--repo", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--ref", required=True)
    p.add_argument("--rebuild", default="", help="true to force a build")
    p.add_argument("--inputs-hash", required=True)
    p.add_argument("--targets", required=True, help="scripts/gen_matrix.py --github targets, .include")
    p.add_argument("--dev-repo", required=True)
    p.add_argument("--run-id", required=True, type=int)
    p.add_argument("--save-candidate", required=True, help="where the verified candidate goes when the mode is reuse")
    e = sub.add_parser("entry")
    e.add_argument("--candidate", required=True)
    e.add_argument("--entry", required=True)
    e.add_argument("--digests-out", required=True)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "plan":
            targets = json.loads(Path(args.targets).read_text())
            decision = decide(
                GhApi(args.repo), event=args.event, ref=args.ref, rebuild=args.rebuild.lower() == "true",
                inputs_hash=args.inputs_hash, targets=targets, dev_repo=args.dev_repo, run_id=args.run_id,
                now=datetime.now(timezone.utc),
            )
            cand = decision.pop("candidate", None)
            if cand is not None:
                Path(args.save_candidate).write_text(json.dumps(cand, indent=2) + "\n")
            json.dump(decision, sys.stdout)
            print()
        else:
            cand = json.loads(Path(args.candidate).read_text())
            entry = json.loads(Path(args.entry).read_text())
            result = entry_digests(cand, entry)
            Path(args.digests_out).write_text(json.dumps(result.pop("digests"), indent=2) + "\n")
            json.dump(result, sys.stdout)
            print()
    except (ReuseError, KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
