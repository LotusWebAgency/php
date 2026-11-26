#!/usr/bin/env python3
"""The release candidate record a develop run leaves behind.

    python3 ci/candidate.py entry --entry ENTRY.json --out TEST_OUT_DIR --created TS --built-run ID --built-sha SHA --repository REPO > record.json
    python3 ci/candidate.py merge --targets TARGETS.json --records DIR --sha SHA --tree TREE \
        --inputs-hash HASH --ci-hash HASH --run-id ID --run-attempt N --out release-candidate.json
    python3 ci/candidate.py check --candidate FILE --sha SHA --inputs-hash HASH --run-id ID
    python3 ci/candidate.py pin --candidate FILE --target NAME --arch ARCH --sha SHA --inputs-hash HASH --run-id ID

`entry` runs in each `images` job after ci/test-images.sh --mode digest: for every target in
passed.txt it records the per-arch index digest the build pushed (the file the merge job reads), the
digest of that architecture's platform manifest (from the signed test-result predicate), the build
timestamp and the run that built it. `merge` runs once in the `candidate` job: it joins the
per-entry records and refuses anything but a complete set, every target of
`scripts/gen_matrix.py --github targets` on every architecture exactly once, so a candidate on
disk always means "this commit's whole matrix was built and passed".

release-candidate.json:
    {"schema": 1, "sha", "tree", "inputs_hash", "ci_hash", "run_id", "run_attempt", "built_run", "built_sha", "repository",
     "targets": {"<name>": {"tag": "8.5-fpm", "archs": {"amd64": {"index", "platform", "created", "built_run", "built_sha"}, ...}}}}

`sha`, `tree`, `run_id` and `run_attempt` name the run that tested and tagged these images (its
digest-<target>-<arch> artifacts and test-result predicates). `created`, `built_run` and `built_sha`
name the build: they are this run's (and its commit's) when it built the images, and the original
build's when ci/reuse_plan.py found the same inputs hash and the images were only re-tested
(`built_run` != `run_id`). `built_sha` is what the images' org.opencontainers.image.revision label
says: the commit `sha` of a reuse run is newer.
`ci_hash` is the sha256 of .github/workflows/ci.yml the images were built under (a reuse run only
reuses images whose `ci_hash` equals its own, so it is still the build's): how the images are built
(bake flags, SBOM, provenance) is not part of the inputs hash, and ci/release_source.py copies a
candidate to the release repository only when it equals main's.

`check` and `pin` are what extended.yml's jobs use to test exactly the images of a candidate and not
whatever a mutable dev:<tag>-<sha12> names later (ci/dev-tag.sh re-points those tags on a rebuild).
`check` refuses a candidate that is not for this commit, this inputs hash and this ci run. `pin`
does the same and prints `<repository>@<index digest><TAB><platform digest><TAB><built_sha>` of one
target on one architecture: the ref to pull, the platform manifest that pull must resolve to and the
revision label the image must carry.
"""
import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA = 1
ARCHES = ("amd64", "arm64")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
TIMESTAMP = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
RUN_ID = re.compile(r"^\d+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


class CandidateError(ValueError):
    pass


def slot_built_sha(cand, slot):
    """The commit that built the image of one slot, or None. A slot or candidate without `built_sha` was
    built by its own run (built_run == run_id), so that run's commit is the build's."""
    found = slot.get("built_sha") or cand.get("built_sha")
    if not found and str(slot.get("built_run") or cand.get("built_run") or cand.get("run_id")) == str(cand.get("run_id")):
        found = cand.get("sha")
    return found if isinstance(found, str) and COMMIT.match(found) else None


def _digest(value, what):
    if not isinstance(value, str) or not DIGEST.match(value):
        raise CandidateError(f"{what}: '{value}' is not a sha256 digest")
    return value


def entry_record(entry, out_dir, created, repository, built_run, built_sha):
    """The passed targets of one images job (one matrix entry) as a record."""
    if not TIMESTAMP.match(created):
        raise CandidateError(f"created '{created}' is not a UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)")
    if not RUN_ID.match(str(built_run)):
        raise CandidateError(f"built run '{built_run}' is not a run id")
    if not COMMIT.match(str(built_sha)):
        raise CandidateError(f"built sha '{built_sha}' is not a commit sha")
    out_dir = Path(out_dir)
    arch = entry["arch"]
    by_name = {t["name"]: t for t in entry["targets"]}
    passed_file = out_dir / "passed.txt"
    if not passed_file.is_file():
        raise CandidateError(f"{passed_file} does not exist: test-images.sh did not finish")
    passed = [line.strip() for line in passed_file.read_text().splitlines() if line.strip()]
    targets = {}
    for name in passed:
        if name not in by_name:
            raise CandidateError(f"{name} is in passed.txt but not in entry {entry['name']}")
        artifact = out_dir / name / "artifact"
        index = _digest((artifact / arch).read_text().strip(), f"{name} index digest")
        result = json.loads((artifact / f"{arch}.test-result.json").read_text())
        platform = _digest(result["platforms"][0]["image_digest"], f"{name} platform digest")
        targets[name] = {"tag": by_name[name]["tag"].split(":", 1)[1], "index": index, "platform": platform}
    return {
        "name": entry["name"],
        "php": entry["php"],
        "uarch": entry["uarch"],
        "arch": arch,
        "created": created,
        "built_run": str(built_run),
        "built_sha": str(built_sha),
        "repository": repository,
        "targets": targets,
    }


def merge_records(records, wanted, sha, tree, inputs_hash, run_id, run_attempt, arches=ARCHES, *, ci_hash):
    """release-candidate.json from the per-entry records, or CandidateError listing every gap."""
    if not SHA256.match(str(ci_hash)):
        raise CandidateError(f"ci hash '{ci_hash}' is not a sha256 hex digest")
    wanted_tags = {t["name"]: t["tags"][0].split(":", 1)[1] for t in wanted}
    problems = []
    repositories = {r["repository"] for r in records}
    if len(repositories) > 1:
        problems.append(f"records name more than one repository: {sorted(repositories)}")
    merged = {}
    for rec in records:
        if not RUN_ID.match(str(rec.get("built_run", ""))):
            problems.append(f"record {rec['name']}: built_run '{rec.get('built_run')}' is not a run id")
            continue
        if not COMMIT.match(str(rec.get("built_sha", ""))):
            problems.append(f"record {rec['name']}: built_sha '{rec.get('built_sha')}' is not a commit sha")
            continue
        if rec["arch"] not in arches:
            problems.append(f"record {rec['name']}: architecture {rec['arch']} is not one of {list(arches)}")
            continue
        for name, found in rec["targets"].items():
            if name not in wanted_tags:
                problems.append(f"record {rec['name']}: {name} is not a target of this matrix")
                continue
            if found["tag"] != wanted_tags[name]:
                problems.append(f"record {rec['name']}: {name} has tag {found['tag']}, expected {wanted_tags[name]}")
                continue
            slot = merged.setdefault(name, {"tag": found["tag"], "archs": {}})["archs"]
            if rec["arch"] in slot:
                problems.append(f"{name} {rec['arch']} is in more than one record")
                continue
            try:
                slot[rec["arch"]] = {
                    "index": _digest(found["index"], f"{name} {rec['arch']} index"),
                    "platform": _digest(found["platform"], f"{name} {rec['arch']} platform"),
                    "created": rec["created"],
                    "built_run": rec["built_run"],
                    "built_sha": rec["built_sha"],
                }
            except CandidateError as exc:
                problems.append(str(exc))
    for name in wanted_tags:
        for arch in arches:
            if arch not in merged.get(name, {}).get("archs", {}):
                problems.append(f"{name} {arch} is missing: it did not build and pass")
    built_runs = {slot["built_run"] for found in merged.values() for slot in found["archs"].values()}
    if len(built_runs) > 1:
        problems.append(f"images come from more than one build run: {sorted(built_runs)}")
    built_shas = {slot["built_sha"] for found in merged.values() for slot in found["archs"].values()}
    if len(built_shas) > 1:
        problems.append(f"images come from more than one build commit: {sorted(built_shas)}")
    if problems:
        raise CandidateError("incomplete candidate:\n  " + "\n  ".join(problems))
    return {
        "schema": SCHEMA,
        "sha": sha,
        "tree": tree,
        "inputs_hash": inputs_hash,
        "ci_hash": ci_hash,
        "run_id": str(run_id),
        "run_attempt": str(run_attempt),
        "built_run": built_runs.pop(),
        "built_sha": built_shas.pop(),
        "repository": repositories.pop(),
        "targets": {name: merged[name] for name in wanted_tags},
    }


def check_header(cand, sha, inputs_hash, run_id):
    """CandidateError unless `cand` is the candidate of ci run `run_id` for commit `sha` and this inputs hash."""
    if not isinstance(cand, dict) or cand.get("schema") != SCHEMA:
        raise CandidateError(f"candidate schema {cand.get('schema') if isinstance(cand, dict) else cand!r} is not {SCHEMA}")
    if cand.get("sha") != sha:
        raise CandidateError(f"candidate is for commit {str(cand.get('sha'))[:12]}, not {sha[:12]}")
    if cand.get("inputs_hash") != inputs_hash:
        raise CandidateError(f"candidate is for inputs hash {str(cand.get('inputs_hash'))[:12]}, not {inputs_hash[:12]}")
    if run_id and str(cand.get("run_id")) != str(run_id):
        raise CandidateError(f"candidate was written by ci run {cand.get('run_id')}, not {run_id}")
    if not isinstance(cand.get("repository"), str) or not cand["repository"]:
        raise CandidateError("candidate names no repository")


def pin(cand, name, arch, sha, inputs_hash, run_id):
    """(`<repository>@<index digest>`, platform digest, build commit) of one target on one architecture of the candidate."""
    check_header(cand, sha, inputs_hash, run_id)
    slot = (((cand.get("targets") or {}).get(name) or {}).get("archs") or {}).get(arch)
    if not slot:
        raise CandidateError(f"candidate has no {name} {arch}")
    index = _digest(slot.get("index"), f"{name} {arch} index")
    platform = _digest(slot.get("platform"), f"{name} {arch} platform")
    built_sha = slot_built_sha(cand, slot)
    if not built_sha:
        raise CandidateError(f"{name} {arch} records no build commit")
    return f"{cand['repository']}@{index}", platform, built_sha


def load_records(directory):
    files = sorted(Path(directory).rglob("*.json"))
    if not files:
        raise CandidateError(f"no records under {directory}")
    return [json.loads(f.read_text()) for f in files]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("entry")
    e.add_argument("--entry", required=True, help="the matrix entry as JSON")
    e.add_argument("--out", required=True, help="ci/test-images.sh's --out directory")
    e.add_argument("--created", required=True)
    e.add_argument("--built-run", required=True, help="the run that built the images: this one, or the one they were reused from")
    e.add_argument("--built-sha", required=True, help="the commit that built the images: this run's, or the one they were reused from")
    e.add_argument("--repository", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--targets", required=True, help="scripts/gen_matrix.py --github targets, .include")
    m.add_argument("--records", required=True, help="directory of entry records")
    m.add_argument("--sha", required=True)
    m.add_argument("--tree", required=True)
    m.add_argument("--inputs-hash", required=True)
    m.add_argument("--ci-hash", required=True, help="sha256 of .github/workflows/ci.yml")
    m.add_argument("--run-id", required=True)
    m.add_argument("--run-attempt", required=True)
    m.add_argument("--out", required=True)
    for cmd in ("check", "pin"):
        c = sub.add_parser(cmd)
        c.add_argument("--candidate", required=True, help="release-candidate.json")
        c.add_argument("--sha", required=True, help="the commit the images must be of (40 hex digits)")
        c.add_argument("--inputs-hash", required=True)
        c.add_argument("--run-id", default="", help="the ci run that wrote the candidate")
        if cmd == "pin":
            c.add_argument("--target", required=True)
            c.add_argument("--arch", required=True, choices=ARCHES)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "check":
            check_header(json.loads(Path(args.candidate).read_text()), args.sha, args.inputs_hash, args.run_id)
            print(f"ok: {args.candidate} is the candidate of {args.sha[:12]}")
        elif args.cmd == "pin":
            ref, platform, built_sha = pin(json.loads(Path(args.candidate).read_text()), args.target, args.arch, args.sha, args.inputs_hash, args.run_id)
            print(f"{ref}\t{platform}\t{built_sha}")
        elif args.cmd == "entry":
            entry = json.loads(Path(args.entry).read_text())
            json.dump(entry_record(entry, args.out, args.created, args.repository, args.built_run, args.built_sha), sys.stdout, indent=2)
            print()
        else:
            wanted = json.loads(Path(args.targets).read_text())
            doc = merge_records(load_records(args.records), wanted, args.sha, args.tree, args.inputs_hash,
                                args.run_id, args.run_attempt, ci_hash=args.ci_hash)
            Path(args.out).write_text(json.dumps(doc, indent=2) + "\n")
            print(f"ok: {len(doc['targets'])} targets x {len(ARCHES)} architectures in {args.out}")
    except (CandidateError, KeyError, OSError, json.JSONDecodeError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
