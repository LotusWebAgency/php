"""ci/reuse_plan.py: the reuse decision over recorded GitHub API responses."""
import contextlib
import copy
import io
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import candidate  # noqa: E402
import reuse_plan  # noqa: E402

DATA = Path(__file__).resolve().parent / "testdata" / "reuse_plan"
# runs.json and artifacts.json are responses of the real API (ci.yml's develop push runs and one
# run's artifacts), trimmed to the fields the code reads. Runs, newest first: 45715121437 success,
# 45684284662 failure, 45586873202 success, 45160117739 success.
RUNS = json.loads((DATA / "runs.json").read_text())
ARTIFACTS = json.loads((DATA / "artifacts.json").read_text())
NEWEST_GREEN = RUNS["workflow_runs"][0]
FAILED = RUNS["workflow_runs"][1]

REPO = "ghcr.io/lotuswebagency/php/dev"
HASH = "a" * 64
CI_HASH = "c" * 64
NOW = datetime(2026, 11, 26, 12, 0, 0, tzinfo=timezone.utc)
THIS_RUN = 45800000000
NAMES = ("php-8_5-fpm", "php-8_5-cli")


def sha(char):
    return "sha256:" + char * 64


def stamp(delta):
    return (NOW - delta).strftime(reuse_plan.TIME_FORMAT)


def targets(names=NAMES):
    return [{"name": n, "tags": [f"lotuswebagency/php:8.5-{n.split('-', 2)[2]}"]} for n in names]


def make_candidate(run=NEWEST_GREEN, inputs_hash=HASH, created=None, names=NAMES, repo=REPO, built_run=None, ci_hash=CI_HASH, built_sha="9" * 40):
    created = created or stamp(timedelta(hours=3))
    records = [
        {
            "name": f"8.5-{arch}", "php": "8.5", "uarch": "baseline", "arch": arch, "created": created,
            "built_run": built_run or str(run["id"]), "built_sha": run["head_sha"] if not built_run else built_sha, "repository": repo,
            "targets": {n: {"tag": f"8.5-{n.split('-', 2)[2]}", "index": sha("1" if arch == "amd64" else "2"), "platform": sha("3")} for n in names},
        }
        for arch in reuse_plan.ARCHES
    ]
    return candidate.merge_records(records, targets(names), run["head_sha"], "t" * 40, inputs_hash, run["id"], 1, ci_hash=ci_hash)


def artifact_doc(run=NEWEST_GREEN, expired=False, name="release-candidate"):
    base = copy.deepcopy(ARTIFACTS["artifacts"][0])
    base.update({"id": 15070000001, "name": name, "expired": expired, "created_at": run["updated_at"]})
    base["workflow_run"]["id"] = run["id"]
    doc = copy.deepcopy(ARTIFACTS)
    doc["artifacts"].append(base)
    return doc


class FakeApi:
    def __init__(self, runs=RUNS, artifacts=None, cand=None):
        self.runs_doc = runs
        self.artifacts_doc = artifacts if artifacts is not None else artifact_doc()
        self.cand = cand if cand is not None else make_candidate()
        self.calls = []

    def runs(self):
        self.calls.append("runs")
        return self.runs_doc

    def artifacts(self, run_id):
        self.calls.append(("artifacts", run_id))
        return self.artifacts_doc

    def candidate(self, artifact_id):
        self.calls.append(("candidate", artifact_id))
        return self.cand


def decide(api, **kw):
    args = dict(event="push", ref="refs/heads/develop", rebuild=False, inputs_hash=HASH, ci_hash=CI_HASH, targets=targets(),
                dev_repo=REPO, run_id=THIS_RUN, now=NOW)
    args.update(kw)
    return reuse_plan.decide(api, **args)


class TestReuse(unittest.TestCase):
    def test_newest_green_run_with_the_same_hash_is_reused(self):
        api = FakeApi()
        got = decide(api)
        self.assertEqual(got["mode"], "reuse", got["reason"])
        self.assertEqual((got["run_id"], got["built_run"]), (str(NEWEST_GREEN["id"]), str(NEWEST_GREEN["id"])))
        self.assertEqual(got["candidate"], api.cand)
        self.assertIn(NEWEST_GREEN["head_sha"][:12], got["reason"])

    def test_dispatch_without_rebuild_reuses(self):
        self.assertEqual(decide(FakeApi(), event="workflow_dispatch")["mode"], "reuse")

    def test_a_reuse_run_is_a_valid_source_and_keeps_the_original_build(self):
        # The newest green run is itself a reuse run: its candidate names run 99 as the build.
        old = stamp(timedelta(days=4, hours=20))
        got = decide(FakeApi(cand=make_candidate(created=old, built_run="99")))
        self.assertEqual((got["mode"], got["built_run"], got["run_id"]), ("reuse", "99", str(NEWEST_GREEN["id"])))

    def test_age_limit_is_five_days_of_the_oldest_image(self):
        self.assertEqual(decide(FakeApi(cand=make_candidate(created=stamp(timedelta(days=4, hours=23)))))["mode"], "reuse")
        got = decide(FakeApi(cand=make_candidate(created=stamp(timedelta(days=5, minutes=1)))))
        self.assertEqual(got["mode"], "build")
        self.assertIn("days ago (limit 5)", got["reason"])

    def test_the_oldest_slot_decides_not_the_first(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-cli"]["archs"]["arm64"]["created"] = stamp(timedelta(days=6))
        self.assertEqual(decide(FakeApi(cand=cand))["mode"], "build")

    def test_the_run_that_was_chosen_is_the_one_read(self):
        api = FakeApi()
        decide(api)
        self.assertEqual(api.calls, ["runs", ("artifacts", NEWEST_GREEN["id"]), ("candidate", 15070000001)])


class TestRunSelection(unittest.TestCase):
    def runs_of(self, *runs):
        return {"total_count": len(runs), "workflow_runs": list(runs)}

    def test_failed_run_is_never_a_source_even_with_a_candidate(self):
        # A red preflight leaves the images job and the candidate job green: the run's own
        # conclusion is what counts.
        api = FakeApi(runs=self.runs_of(FAILED), artifacts=artifact_doc(FAILED), cand=make_candidate(FAILED))
        got = decide(api)
        self.assertEqual(got["mode"], "build")
        self.assertIn("no successful develop push run", got["reason"])
        self.assertEqual(api.calls, ["runs"])

    def test_the_older_green_run_is_used_when_the_newest_is_red(self):
        older = RUNS["workflow_runs"][2]
        failed_newest = copy.deepcopy(NEWEST_GREEN)
        failed_newest.update({"id": 1, "conclusion": "failure"})
        api = FakeApi(runs=self.runs_of(failed_newest, older), artifacts=artifact_doc(older), cand=make_candidate(older))
        got = decide(api)
        self.assertEqual((got["mode"], got["run_id"]), ("reuse", str(older["id"])))
        self.assertIn(("artifacts", older["id"]), api.calls)
        self.assertNotIn(("artifacts", 1), api.calls)

    def test_newest_by_creation_time_whatever_the_order_of_the_list(self):
        older = RUNS["workflow_runs"][2]
        api = FakeApi(runs=self.runs_of(older, NEWEST_GREEN))
        self.assertEqual(decide(api)["run_id"], str(NEWEST_GREEN["id"]))

    def test_unfinished_canceled_and_foreign_runs_are_skipped(self):
        def variant(**kw):
            r = copy.deepcopy(NEWEST_GREEN)
            r.update(kw)
            return r
        runs = self.runs_of(
            variant(id=11, status="in_progress", conclusion=None),
            variant(id=12, conclusion="cancelled"),
            variant(id=13, head_branch="main"),
            variant(id=14, event="workflow_dispatch"),
            variant(id=15, path=".github/workflows/extended.yml"),
        )
        self.assertIn("no successful develop push run", decide(FakeApi(runs=runs))["reason"])

    def test_this_run_is_not_its_own_source(self):
        api = FakeApi(runs=self.runs_of(NEWEST_GREEN))
        self.assertEqual(decide(api, run_id=NEWEST_GREEN["id"])["mode"], "build")

    def test_no_runs_at_all(self):
        self.assertEqual(decide(FakeApi(runs={"total_count": 0, "workflow_runs": []}))["mode"], "build")


class TestBuild(unittest.TestCase):
    def build_reason(self, api, **kw):
        got = decide(api, **kw)
        self.assertEqual(got["mode"], "build", got)
        self.assertNotIn("candidate", got)
        return got["reason"]

    def test_expired_artifact(self):
        self.assertIn("has expired", self.build_reason(FakeApi(artifacts=artifact_doc(expired=True))))

    def test_no_candidate_artifact(self):
        self.assertIn("left no release-candidate artifact", self.build_reason(FakeApi(artifacts=ARTIFACTS)))

    def test_other_artifacts_do_not_count(self):
        self.assertIn("left no release-candidate", self.build_reason(FakeApi(artifacts=artifact_doc(name="candidate-8.5-amd64"))))

    def test_an_unexpired_copy_beats_an_expired_one(self):
        doc = artifact_doc(expired=True)
        fresh = copy.deepcopy(doc["artifacts"][-1])
        fresh.update({"id": 15070000002, "expired": False})
        doc["artifacts"].append(fresh)
        api = FakeApi(artifacts=doc)
        self.assertEqual(decide(api)["mode"], "reuse")
        self.assertIn(("candidate", 15070000002), api.calls)

    def test_inputs_hash_mismatch(self):
        reason = self.build_reason(FakeApi(cand=make_candidate(inputs_hash="b" * 64)))
        self.assertIn("inputs hash changed", reason)
        self.assertIn("bbbbbbbbbbbb -> aaaaaaaaaaaa", reason)

    def test_ci_workflow_changed_since_the_build(self):
        reason = self.build_reason(FakeApi(cand=make_candidate(ci_hash="d" * 64)))
        self.assertIn("ci.yml changed", reason)
        self.assertIn("dddddddddddd -> cccccccccccc", reason)

    def test_candidate_without_a_ci_hash(self):
        cand = make_candidate()
        del cand["ci_hash"]
        self.assertIn("ci.yml changed", self.build_reason(FakeApi(cand=cand)))

    def test_images_of_another_run_without_a_build_commit_are_built_again(self):
        cand = make_candidate(built_run="99")
        for t in cand["targets"].values():
            for slot in t["archs"].values():
                del slot["built_sha"]
        del cand["built_sha"]
        self.assertIn("records no build commit", self.build_reason(FakeApi(cand=cand)))

    def test_a_build_run_that_is_not_a_number(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-fpm"]["archs"]["amd64"]["built_run"] = "1\nPATH=/x"
        self.assertIn("build run", self.build_reason(FakeApi(cand=cand)))

    def test_missing_target(self):
        reason = self.build_reason(FakeApi(cand=make_candidate(names=("php-8_5-fpm",))))
        self.assertIn("php-8_5-cli is missing", reason)

    def test_missing_architecture(self):
        cand = make_candidate()
        del cand["targets"]["php-8_5-fpm"]["archs"]["arm64"]
        self.assertIn("php-8_5-fpm arm64 is missing", self.build_reason(FakeApi(cand=cand)))

    def test_target_the_matrix_no_longer_has(self):
        reason = self.build_reason(FakeApi(cand=make_candidate(names=NAMES + ("php-8_5-cli-builder",))))
        self.assertIn("php-8_5-cli-builder is not a target of this matrix", reason)

    def test_tag_drift(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-fpm"]["tag"] = "8.5-other"
        self.assertIn("expected 8.5-fpm", self.build_reason(FakeApi(cand=cand)))

    def test_malformed_digest(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-cli"]["archs"]["amd64"]["index"] = "latest"
        self.assertIn("no valid digests", self.build_reason(FakeApi(cand=cand)))

    def test_candidate_of_another_commit(self):
        cand = make_candidate()
        cand["sha"] = "f" * 40
        self.assertIn("candidate names commit", self.build_reason(FakeApi(cand=cand)))

    def test_candidate_in_another_repository(self):
        self.assertIn("not " + REPO, self.build_reason(FakeApi(cand=make_candidate(repo="ghcr.io/other/dev"))))

    def test_unknown_schema(self):
        cand = make_candidate()
        cand["schema"] = 2
        self.assertIn("schema 2", self.build_reason(FakeApi(cand=cand)))

    def test_unparsable_created(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-fpm"]["archs"]["amd64"]["created"] = "yesterday"
        self.assertIn("not a UTC timestamp", self.build_reason(FakeApi(cand=cand)))

    def test_dispatch_rebuild_does_not_even_look(self):
        api = FakeApi()
        self.assertEqual(self.build_reason(api, event="workflow_dispatch", rebuild=True), "a rebuild was requested")
        self.assertEqual(api.calls, [])

    def test_pull_request_main_and_schedule_always_build(self):
        for event, ref in (("pull_request", "refs/pull/7/merge"), ("push", "refs/heads/main"),
                           ("schedule", "refs/heads/main"), ("workflow_dispatch", "refs/heads/main"),
                           ("pull_request", "refs/heads/develop")):
            with self.subTest(event=event, ref=ref):
                api = FakeApi()
                self.assertIn("always builds", self.build_reason(api, event=event, ref=ref))
                self.assertEqual(api.calls, [])

    def test_malformed_run_list_builds(self):
        self.assertIn("unexpected shape", self.build_reason(FakeApi(runs={"workflow_runs": [{"id": 5, "event": "push", "head_branch": "develop", "path": "x/ci.yml", "status": "completed", "conclusion": "success"}]})))


def completed(stdout=b"", returncode=0, stderr=b""):
    return subprocess.CompletedProcess([], returncode, stdout, stderr)


class TestGhApi(unittest.TestCase):
    def test_reads_runs_artifacts_and_the_zipped_candidate(self):
        cand = make_candidate()
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("release-candidate.json", json.dumps(cand))
        answers = {
            "runs?branch=develop&event=push&status=success&per_page=20": json.dumps(RUNS).encode(),
            "artifacts?name=release-candidate&per_page=20": json.dumps(ARTIFACTS).encode(),
            "/zip": buf.getvalue(),
        }
        seen = []

        def run(cmd, **kw):
            seen.append(cmd)
            self.assertEqual(cmd[:2], ["gh", "api"])
            return completed(next(v for k, v in answers.items() if cmd[2].endswith(k)))

        api = reuse_plan.GhApi("LotusWebAgency/php", run=run)
        self.assertEqual(api.runs(), RUNS)
        self.assertEqual(api.artifacts(7), ARTIFACTS)
        self.assertEqual(api.candidate(8), cand)
        self.assertEqual(seen[1][2], "repos/LotusWebAgency/php/actions/runs/7/artifacts?name=release-candidate&per_page=20")
        self.assertEqual(seen[2][2], "repos/LotusWebAgency/php/actions/artifacts/8/zip")

    def test_a_failing_call_means_build_not_a_failed_plan(self):
        def run(cmd, **kw):
            raise subprocess.CalledProcessError(1, cmd, b"", b"HTTP 403: Resource not accessible by integration")

        got = decide(reuse_plan.GhApi("o/r", run=run))
        self.assertEqual(got["mode"], "build")
        self.assertIn("HTTP 403", got["reason"])

    def test_a_transient_failure_is_retried_and_the_decision_is_normal(self):
        cand = make_candidate()
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("release-candidate.json", json.dumps(cand))
        answers = {"runs?": json.dumps(RUNS).encode(), "artifacts?": json.dumps(artifact_doc()).encode(), "/zip": buf.getvalue()}
        calls, slept = {}, []

        def run(cmd, **kw):
            key = next(k for k in answers if k in cmd[2])
            calls[key] = calls.get(key, 0) + 1
            if calls[key] == 1:
                raise subprocess.CalledProcessError(1, cmd, b"", b"gh: Bad Gateway (HTTP 502)")
            return completed(answers[key])

        got = decide(reuse_plan.GhApi("o/r", run=run, sleep=slept.append))
        self.assertEqual(got["mode"], "reuse", got)
        self.assertEqual(calls, {"runs?": 2, "artifacts?": 2, "/zip": 2})
        self.assertEqual(slept, [5, 5, 5])

    def test_a_timeout_and_a_dropped_connection_are_retried(self):
        for failure in (subprocess.TimeoutExpired(["gh"], 300), subprocess.CalledProcessError(1, ["gh"], b"", b"error connecting to api.github.com")):
            seen = []

            def run(cmd, **kw):
                seen.append(cmd)
                if len(seen) == 1:
                    raise failure
                return completed(b"{}")

            self.assertEqual(reuse_plan.GhApi("o/r", run=run, sleep=lambda s: None)._json("x"), {})
            self.assertEqual(len(seen), 2)

    def test_a_persistent_failure_is_three_attempts_then_build(self):
        seen, slept = [], []

        def run(cmd, **kw):
            seen.append(cmd)
            raise subprocess.CalledProcessError(1, cmd, b"", b"gh: Service Unavailable (HTTP 503)")

        got = decide(reuse_plan.GhApi("o/r", run=run, sleep=slept.append))
        self.assertEqual(got["mode"], "build")
        self.assertIn("HTTP 503", got["reason"])
        self.assertEqual(len(seen), 3)
        self.assertEqual(slept, [5, 15])

    def test_a_final_error_is_not_retried(self):
        for stderr in (b"gh: Not Found (HTTP 404)", b"gh: Resource not accessible by integration (HTTP 403)", b"gh: Bad credentials (HTTP 401)"):
            seen = []

            def run(cmd, **kw):
                seen.append(cmd)
                raise subprocess.CalledProcessError(1, cmd, b"", stderr)

            with self.assertRaises(reuse_plan.NoReuse):
                reuse_plan.GhApi("o/r", run=run, sleep=lambda s: self.fail("slept"))._get("x")
            self.assertEqual(len(seen), 1, stderr)

    def test_a_zip_without_the_file_means_build(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("other.json", "{}")
        api = reuse_plan.GhApi("o/r", run=lambda cmd, **kw: completed(buf.getvalue()))
        with self.assertRaises(reuse_plan.NoReuse):
            api.candidate(1)

    def test_not_a_zip_means_build(self):
        api = reuse_plan.GhApi("o/r", run=lambda cmd, **kw: completed(b"<html>"))
        with self.assertRaises(reuse_plan.NoReuse):
            api.candidate(1)


def entry(arch="arm64", names=NAMES):
    return {
        "name": f"8.5-{arch}", "php": "8.5", "uarch": "baseline", "arch": arch,
        "targets": [{"name": n, "flavor": n.split("-", 2)[2], "tag": f"lotuswebagency/php:8.5-{n.split('-', 2)[2]}"} for n in names],
    }


class TestEntryDigests(unittest.TestCase):
    def test_digests_created_and_build_of_the_entrys_arch(self):
        cand = make_candidate(created="2026-11-23T08:00:00Z", built_run="99")
        got = reuse_plan.entry_digests(cand, entry("arm64"))
        self.assertEqual(got["digests"], {n: f"{REPO}@{sha('2')}" for n in NAMES})
        self.assertEqual((got["created"], got["built_run"], got["built_sha"]), ("2026-11-23T08:00:00Z", "99", "9" * 40))
        self.assertEqual(reuse_plan.entry_digests(cand, entry("amd64"))["digests"]["php-8_5-fpm"], f"{REPO}@{sha('1')}")

    def test_a_candidate_from_before_built_run_falls_back_to_its_run(self):
        cand = make_candidate()
        for t in cand["targets"].values():
            for slot in t["archs"].values():
                del slot["built_run"]
        del cand["built_run"]
        self.assertEqual(reuse_plan.entry_digests(cand, entry())["built_run"], str(NEWEST_GREEN["id"]))

    def test_a_candidate_that_built_its_own_images_names_its_commit_as_the_build(self):
        cand = make_candidate()
        self.assertEqual(reuse_plan.entry_digests(cand, entry())["built_sha"], NEWEST_GREEN["head_sha"])

    def test_a_build_commit_that_could_inject_into_the_environment(self):
        cand = make_candidate(built_run="99")
        for arch in reuse_plan.ARCHES:
            for t in cand["targets"].values():
                t["archs"][arch]["built_sha"] = "9" * 40 + "\nPATH=/x"
        cand["built_sha"] = "9" * 40 + "\nPATH=/x"
        with self.assertRaisesRegex(reuse_plan.ReuseError, "no build commit"):
            reuse_plan.entry_digests(cand, entry())

    def test_a_missing_target_is_an_error(self):
        with self.assertRaisesRegex(reuse_plan.ReuseError, "no php-8_5-cli-builder arm64"):
            reuse_plan.entry_digests(make_candidate(), entry(names=NAMES + ("php-8_5-cli-builder",)))

    def test_a_build_run_or_time_that_could_inject_into_the_environment(self):
        cand = make_candidate(built_run="99")
        for arch in reuse_plan.ARCHES:
            for t in cand["targets"].values():
                t["archs"][arch]["built_run"] = "99\nPATH=/x"
        with self.assertRaisesRegex(reuse_plan.ReuseError, "not a run id"):
            reuse_plan.entry_digests(cand, entry())
        cand = make_candidate(built_run="99")
        cand["targets"]["php-8_5-fpm"]["archs"]["arm64"]["created"] = "2026-11-23T08:00:00Z\nX=1"
        with self.assertRaisesRegex(reuse_plan.ReuseError, "not a UTC timestamp"):
            reuse_plan.entry_digests(cand, entry())

    def test_one_entry_never_spans_two_builds(self):
        cand = make_candidate(built_run="99")
        cand["targets"]["php-8_5-cli"]["archs"]["arm64"]["built_run"] = "98"
        with self.assertRaisesRegex(reuse_plan.ReuseError, "more than one build run"):
            reuse_plan.entry_digests(cand, entry())


class TestCli(unittest.TestCase):
    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = reuse_plan.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def plan_args(self, tmp, **over):
        (tmp / "targets.json").write_text(json.dumps(targets()))
        args = {"--repo": "LotusWebAgency/php", "--event": "push", "--ref": "refs/heads/develop", "--rebuild": "",
                "--inputs-hash": HASH, "--ci-hash": CI_HASH, "--targets": str(tmp / "targets.json"), "--dev-repo": REPO,
                "--run-id": str(THIS_RUN), "--save-candidate": str(tmp / "candidate.json")}
        args.update(over)
        return [x for kv in args.items() for x in kv]

    def test_plan_saves_the_verified_candidate_for_reuse_only(self):
        api = FakeApi()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(reuse_plan, "GhApi", return_value=api):
            tmp = Path(tmp)
            now = mock.Mock(wraps=datetime)
            now.now.return_value = NOW
            with mock.patch.object(reuse_plan, "datetime", now):
                rc, out, _ = self.run_cli("plan", *self.plan_args(tmp))
                self.assertEqual(rc, 0)
                decision = json.loads(out)
                self.assertEqual((decision["mode"], decision["run_id"]), ("reuse", str(NEWEST_GREEN["id"])))
                self.assertNotIn("candidate", decision)
                self.assertEqual(json.loads((tmp / "candidate.json").read_text()), api.cand)
                (tmp / "candidate.json").unlink()
                rc, out, _ = self.run_cli("plan", *self.plan_args(tmp, **{"--rebuild": "true", "--event": "workflow_dispatch"}))
                self.assertEqual((rc, json.loads(out)["mode"]), (0, "build"))
                self.assertFalse((tmp / "candidate.json").exists())

    def test_entry_writes_the_digest_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "candidate.json").write_text(json.dumps(make_candidate(built_run="99")))
            (tmp / "entry.json").write_text(json.dumps(entry()))
            rc, out, _ = self.run_cli("entry", "--candidate", str(tmp / "candidate.json"), "--entry", str(tmp / "entry.json"),
                                      "--digests-out", str(tmp / "digests.json"))
            self.assertEqual(rc, 0)
            self.assertEqual(json.loads(out)["built_run"], "99")
            self.assertEqual(sorted(json.loads((tmp / "digests.json").read_text())), sorted(NAMES))

    def test_entry_of_an_incomplete_candidate_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "candidate.json").write_text(json.dumps(make_candidate(names=("php-8_5-fpm",))))
            (tmp / "entry.json").write_text(json.dumps(entry()))
            rc, _, err = self.run_cli("entry", "--candidate", str(tmp / "candidate.json"), "--entry", str(tmp / "entry.json"),
                                      "--digests-out", str(tmp / "digests.json"))
            self.assertEqual(rc, 1)
            self.assertIn("no php-8_5-cli arm64", err)
            self.assertFalse((tmp / "digests.json").exists())


if __name__ == "__main__":
    unittest.main()
