#!/usr/bin/env python3
"""Release main's images by copying the ones develop already built and tested.

    python3 ci/release_source.py decide --mode main|promote --repo OWNER/REPO --inputs-hash H --ci-hash H \
        --targets TARGETS.json --dev-repo REPO --hold "$RELEASE_HOLD" --save-candidate FILE [--head-sha SHA] [--output FILE] > decision.json
    python3 ci/release_source.py target --candidate FILE --target NAME --digests DIR

`decide` answers one question: are the images on php/dev the ones this checkout would publish, so
that main only has to copy, rescan, sign and attest them? It runs in the `release-source` job on a
push to main (`--mode main`; the answer is `copy` or `rebuild`, and a rebuild never fails the run)
and in `promote-check` on a pull request from develop to main (`--mode promote`: the same checks
applied to the PR head). There the answer is a decision, not a gate: `copy` or `rebuild` goes to
`--output` as `copy=true|false` and a rebuild is exit 0, so the PR runs the subset build instead of
the copy path. Only a PR that must not merge exits 1: RELEASE_HOLD set, a merge ref that is not a
merge of the PR head, a merge ref whose tree is not the head's, or git failing.

A merge commit of develop into main publishes develop's tree unchanged; D below is its second
parent, the develop commit that was tested. `copy` needs all of these:
  - HEAD has exactly two parents and HEAD^{tree} equals D^{tree}: nothing is on main that was
    not on develop. In `promote` mode HEAD is the PR's merge ref and D must be the PR head;
  - the repository variable RELEASE_HOLD is empty;
  - the newest ci.yml run for D is a push to develop in this repository, completed with the
    conclusion `success` for the run as a whole (not only `images`);
  - D has an extended.yml run that is the one the `ci` run above started: event `workflow_run`
    (GitHub runs a workflow_run workflow from the default branch's copy, which only a merge to
    main can change), path `.github/workflows/extended.yml`, concluded `success`, and a title
    that is exactly `extended <D> ci <ci run id>.<ci run attempt>` (the workflow's `run-name`),
    with that attempt the latest of the ci run. It tested D's images with D's own tree. A
    dispatch from any branch, a push to extended-run or a re-run of the ci run since all have
    another event or another title. The newest `release/extended` commit status of D, which
    must be `success`, is only the pointer to that run; its creator and text prove nothing;
  - that ci run built every image itself: the candidate's `built_run` (top level and every
    architecture of every target) is the ci run's own id. A run that reused older images
    skipped the PGO check on them, and main does not copy such images;
  - that ci run left an unexpired `release-candidate` artifact (ci/candidate.py) for D: this tree,
    this inputs hash, the sha256 of this tree's ci.yml (how the images are built is not part of the
    inputs hash), the dev repository, every target on both architectures and nothing else, written
    by that run, with the oldest image at most seven days old.
Anything else, including any failure to read GitHub, is not `copy`, with the reason in the output.

`target` runs in each `merge` leg of a copy: the digest-<target>-<arch> artifacts downloaded from
the develop run must hold exactly the digests the candidate records, so a leg can never publish
anything the decision was not made on, and the oldest image must still be at most seven days old
now (a re-run of a failed leg days later reuses the old decision, not its age check).
"""
import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import reuse_plan
from reuse_plan import NoReuse

MAX_AGE = timedelta(days=7)
STATUS_CONTEXT = "release/extended"
EXTENDED_PATH = ".github/workflows/extended.yml"
SHA = re.compile(r"^[0-9a-f]{40}$")


class NotCopy(NoReuse):
    """The reason this release is not a copy."""


class Blocked(NotCopy):
    """A reason that also stops a promote PR from merging: a hold, or a merge ref that is not the PR head's tree."""


class Git:
    """The two things read from the checkout: the parents of HEAD and trees."""

    def __init__(self, run=subprocess.run):
        self.run = run

    def _out(self, *args):
        try:
            done = self.run(["git", *args], capture_output=True, text=True, check=True, timeout=60)
        except (subprocess.SubprocessError, OSError) as exc:
            raise Blocked(f"git {' '.join(args)} failed: {getattr(exc, 'stderr', '') or exc}") from None
        return done.stdout.strip()

    def parents(self):
        commit, *parents = self._out("rev-list", "--parents", "-n1", "HEAD").split()
        return commit, parents

    def tree(self, rev):
        return self._out("rev-parse", f"{rev}^{{tree}}")


class ReleaseApi(reuse_plan.GhApi):
    """GhApi plus the calls about the develop commit: its ci runs, statuses and an extended run."""

    def ci_runs(self, sha):
        return self._json(f"repos/{self.repo}/actions/workflows/ci.yml/runs?head_sha={sha}&branch=develop&event=push&per_page=20")

    def statuses(self, sha):
        return self._json(f"repos/{self.repo}/commits/{sha}/statuses?per_page=100")

    def run(self, run_id):
        return self._json(f"repos/{self.repo}/actions/runs/{run_id}")


def develop_commit(git, mode, head_sha):
    """D, the develop commit whose images this checkout would publish, or NotCopy."""
    commit, parents = git.parents()
    if len(parents) != 2:
        raise Blocked(f"HEAD has {len(parents)} parent(s), not the two of a merge of develop")
    d = parents[1]
    if mode == "promote":
        if head_sha and d != head_sha:
            raise Blocked(f"the merge ref's second parent {d[:12]} is not the PR head {head_sha[:12]}")
    elif not SHA.match(d):
        raise NotCopy(f"second parent '{d}' is not a commit sha")
    head_tree, d_tree = git.tree("HEAD"), git.tree(d)
    if head_tree != d_tree:
        raise Blocked(f"the merge changes the tree: {head_tree[:12]} is not {d_tree[:12]} ({d[:12]}); main has content develop never tested")
    return d, head_tree


def ci_run(api, sha, repo):
    """The newest ci.yml push run of develop for `sha`: it must have completed with success."""
    runs = [
        r for r in api.ci_runs(sha).get("workflow_runs", [])
        if r.get("head_sha") == sha
        and r.get("event") == "push"
        and r.get("head_branch") == "develop"
        and r.get("path", "").endswith("/ci.yml")
        and (r.get("head_repository") or {}).get("full_name") == repo
    ]
    if not runs:
        raise NotCopy(f"no develop push run of ci.yml for {sha[:12]}")
    run = max(runs, key=lambda r: (r["created_at"], r["id"]))
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise NotCopy(f"the ci run {run['id']} for {sha[:12]} is {run.get('status')}/{run.get('conclusion')}, not a success")
    return run


def extended_title(sha, ci):
    """The run-name extended.yml gives a workflow_run run that tested `sha` for this attempt of this ci run."""
    return f"extended {sha} ci {ci['id']}.{ci['run_attempt']}"


def extended_run(api, sha, repo, ci):
    """The id of the extended.yml run that tested `sha` for this very ci run and attempt, which must have passed.

    The newest `release/extended` status of `sha` only points at a run; nothing it says is trusted.
    """
    if not re.fullmatch(r"\d+", str(ci.get("run_attempt"))):
        raise NotCopy(f"the ci run {ci['id']} has no run attempt")
    found = [s for s in api.statuses(sha) if s.get("context") == STATUS_CONTEXT]
    if not found:
        raise NotCopy(f"{sha[:12]} has no {STATUS_CONTEXT} status: no extended.yml run of ci run {ci['id']}.{ci['run_attempt']} has finished (it starts when that ci run completes)")
    status = max(found, key=lambda s: (s["created_at"], s["id"]))
    if status.get("state") != "success":
        raise NotCopy(f"the {STATUS_CONTEXT} status of {sha[:12]} is {status.get('state')}")
    target = re.fullmatch(rf"https://github\.com/{re.escape(repo)}/actions/runs/(\d+)", status.get("target_url") or "")
    if not target:
        raise NotCopy(f"the {STATUS_CONTEXT} status of {sha[:12]} targets '{status.get('target_url')}', not a run of {repo}")
    run = api.run(target.group(1))
    where = f"the {STATUS_CONTEXT} status of {sha[:12]} targets run {target.group(1)}, which"
    if str(run.get("id")) != target.group(1) or (run.get("repository") or {}).get("full_name") != repo:
        raise NotCopy(f"{where} is not a run of {repo}")
    if run.get("path") != EXTENDED_PATH:
        raise NotCopy(f"{where} is not an extended.yml run ({run.get('path')})")
    if run.get("event") != "workflow_run":
        raise NotCopy(f"{where} was started by {run.get('event')}, not by the completion of the ci run")
    want = extended_title(sha, ci)
    if run.get("display_title") != want:
        raise NotCopy(f"{where} is titled '{run.get('display_title')}', not '{want}': it tested another commit or another attempt of the ci run")
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        raise NotCopy(f"extended run {run.get('id')} is {run.get('status')}/{run.get('conclusion')}, not a success")
    return run["id"]


def built_by(cand, ci):
    """NotCopy unless every image of the candidate was built, and so tested in full, by `ci` itself."""
    want = str(ci["id"])
    seen = {str(cand.get("built_run") or cand["run_id"])}
    for target in (cand.get("targets") or {}).values():
        for slot in (target.get("archs") or {}).values():
            seen.add(str(slot.get("built_run", cand["run_id"])))
    if seen != {want}:
        raise NotCopy(f"the images were built by run(s) {', '.join(sorted(seen))}, not by ci run {want}: a run that reused images skipped checks on them, so main rebuilds")


def oldest_created(cand):
    """The oldest `created` of the candidate's images, or NotCopy."""
    try:
        return min(
            reuse_plan.parse_time(slot.get("created"), f"{name} {arch} created")
            for name, target in cand["targets"].items() for arch, slot in target["archs"].items()
        )
    except NoReuse as exc:
        raise NotCopy(str(exc)) from None
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        raise NotCopy(f"cannot read the creation times of the candidate ({type(exc).__name__}: {exc})") from None


def decide(api, git, *, mode, repo, inputs_hash, ci_hash, targets, dev_repo, hold, head_sha="", now, max_age=MAX_AGE):
    """{"mode": "copy"|"rebuild", "reason", "blocked": true for a promote PR that must not merge, and for a copy "sha", "run_id", "extended_run", "built_run", "candidate"}; built_run is run_id."""
    try:
        if str(hold).strip():
            raise Blocked(f"RELEASE_HOLD is set ({str(hold).strip()[:200]})")
        d, tree = develop_commit(git, mode, head_sha)
        run = ci_run(api, d, repo)
        extended = extended_run(api, d, repo, run)
        artifact = reuse_plan.candidate_artifact(api.artifacts(run["id"]), run["id"])
        cand = api.candidate(artifact["id"])
        oldest = reuse_plan.check_candidate(cand, run, inputs_hash, targets, dev_repo, now, max_age, ci_hash=ci_hash)
        if cand.get("tree") != tree:
            raise NotCopy(f"the candidate was written for tree {str(cand.get('tree'))[:12]}, this is {tree[:12]}")
        if str(cand.get("run_id")) != str(run["id"]):
            raise NotCopy(f"the candidate says run {cand.get('run_id')} made it, it is an artifact of run {run['id']}")
        built_by(cand, run)
    except NoReuse as exc:
        decision = {"mode": "rebuild", "reason": str(exc)}
        if mode == "promote" and isinstance(exc, Blocked):
            decision["blocked"] = True
        return decision
    except (KeyError, TypeError, AttributeError, ValueError) as exc:
        return {"mode": "rebuild", "reason": f"unexpected shape of the GitHub data ({type(exc).__name__}: {exc})"}
    return {
        "mode": "copy",
        "reason": f"{d[:12]} was built and tested by ci run {run['id']} and extended run {extended}; its oldest image is from {oldest.strftime(reuse_plan.TIME_FORMAT)}",
        "sha": d,
        "run_id": str(run["id"]),
        "extended_run": str(extended),
        "built_run": str(cand.get("built_run") or cand["run_id"]),
        "candidate": cand,
    }


def verify_target(cand, name, digests_dir, now=None):
    """Problems (a list of strings) between one target's downloaded digest files and the candidate.

    With `now`, the candidate's oldest image must also still be within MAX_AGE: the decision it was
    made under may be days old when a failed leg is re-run.
    """
    digests_dir = Path(digests_dir)
    if now is not None:
        try:
            oldest = oldest_created(cand)
        except NotCopy as exc:
            return [str(exc)]
        if now - oldest > MAX_AGE:
            return [f"the oldest image was built {oldest.strftime(reuse_plan.TIME_FORMAT)}, over {MAX_AGE.days} days before {now.strftime(reuse_plan.TIME_FORMAT)}: rebuild instead of copying"]
    found = (cand.get("targets") or {}).get(name)
    if not found:
        return [f"the candidate has no target {name}"]
    problems = []
    on_disk = sorted(p.name for p in digests_dir.iterdir()) if digests_dir.is_dir() else []
    want_files = sorted(f"{a}{ext}" for a in reuse_plan.ARCHES for ext in ("", ".test-result.json"))
    if on_disk != want_files:
        problems.append(f"{digests_dir} holds {on_disk}, expected {want_files}")
        return problems
    for arch in reuse_plan.ARCHES:
        slot = (found.get("archs") or {}).get(arch) or {}
        index = (digests_dir / arch).read_text().strip()
        if index != slot.get("index"):
            problems.append(f"{name} {arch}: the artifact says index {index}, the candidate {slot.get('index')}")
        try:
            platform = json.loads((digests_dir / f"{arch}.test-result.json").read_text())["platforms"][0]["image_digest"]
        except (KeyError, IndexError, TypeError, json.JSONDecodeError):
            problems.append(f"{name} {arch}: no platform digest in the test-result predicate")
            continue
        if platform != slot.get("platform"):
            problems.append(f"{name} {arch}: the predicate is for platform {platform}, the candidate says {slot.get('platform')}")
    return problems


def _now():
    return datetime.now(timezone.utc)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--mode", required=True, choices=("main", "promote"))
    d.add_argument("--repo", required=True)
    d.add_argument("--inputs-hash", required=True)
    d.add_argument("--ci-hash", required=True, help="sha256 of .github/workflows/ci.yml")
    d.add_argument("--targets", required=True, help="scripts/gen_matrix.py --github targets, .include")
    d.add_argument("--dev-repo", required=True)
    d.add_argument("--hold", default="", help="the RELEASE_HOLD repository variable")
    d.add_argument("--head-sha", default="", help="promote mode: the PR head the merge ref must contain")
    d.add_argument("--save-candidate", required=True, help="where the verified candidate goes when the mode is copy")
    d.add_argument("--output", help="append copy=true|false here (the GITHUB_OUTPUT file) unless the PR is blocked")
    t = sub.add_parser("target")
    t.add_argument("--candidate", required=True)
    t.add_argument("--target", required=True)
    t.add_argument("--digests", required=True, help="the downloaded digest-<target>-<arch> files, one directory")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "decide":
            targets = json.loads(Path(args.targets).read_text())
            decision = decide(
                ReleaseApi(args.repo), Git(), mode=args.mode, repo=args.repo, inputs_hash=args.inputs_hash,
                ci_hash=args.ci_hash, targets=targets, dev_repo=args.dev_repo, hold=args.hold,
                head_sha=args.head_sha, now=_now(),
            )
            cand = decision.pop("candidate", None)
            if cand is not None:
                Path(args.save_candidate).write_text(json.dumps(cand, indent=2) + "\n")
            json.dump(decision, sys.stdout)
            print()
            if decision.get("blocked"):
                print(f"FAIL: {decision['reason']}", file=sys.stderr)
                return 1
            if args.output:
                with open(args.output, "a") as out:
                    out.write(f"copy={'true' if decision['mode'] == 'copy' else 'false'}\n")
        else:
            problems = verify_target(json.loads(Path(args.candidate).read_text()), args.target, args.digests, _now())
            if problems:
                print("FAIL: " + "\n  ".join(problems), file=sys.stderr)
                return 1
            print(f"ok: {args.target} matches the candidate")
    except (KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
