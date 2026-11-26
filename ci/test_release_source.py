"""ci/release_source.py: the copy-or-rebuild decision for a release of main, over fake git and GitHub."""
import contextlib
import copy
import io
import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ci"))

import candidate  # noqa: E402
import release_source  # noqa: E402
import reuse_plan  # noqa: E402
from test_reuse_plan import CI_HASH, HASH, NAMES, NOW, REPO, sha, stamp, targets  # noqa: E402

SLUG = "LotusWebAgency/php"
D = "d" * 40
MERGE = "m" * 40
FIRST = "f" * 40
TREE = "t" * 40
CI_RUN = 700
EXT_RUN = 800


class FakeGit:
    def __init__(self, parents=(FIRST, D), trees=None):
        self._parents = list(parents)
        self.trees = trees or {"HEAD": TREE, D: TREE}

    def parents(self):
        return MERGE, self._parents

    def tree(self, rev):
        return self.trees[rev]


def ci_run(**kw):
    run = {
        "id": CI_RUN, "run_attempt": 1, "head_sha": D, "head_branch": "develop", "event": "push", "path": ".github/workflows/ci.yml",
        "status": "completed", "conclusion": "success", "created_at": "2026-11-26T08:00:00Z",
        "head_repository": {"full_name": SLUG},
    }
    run.update(kw)
    return run


def status(**kw):
    s = {
        "id": 1, "context": "release/extended", "state": "success", "created_at": "2026-11-26T10:00:00Z",
        "creator": {"login": "github-actions[bot]"}, "description": "extended tests passed",
        "target_url": f"https://github.com/{SLUG}/actions/runs/{EXT_RUN}",
    }
    s.update(kw)
    return s


def ext_run(**kw):
    run = {"id": EXT_RUN, "path": ".github/workflows/extended.yml", "event": "workflow_run",
           "display_title": f"extended {D} ci {CI_RUN}.1", "status": "completed", "conclusion": "success",
           "repository": {"full_name": SLUG}}
    run.update(kw)
    return run


def make_candidate(created=None, built_run=CI_RUN, **kw):
    created = created or stamp(timedelta(hours=3))
    records = [
        {
            "name": f"8.5-{arch}", "php": "8.5", "uarch": "baseline", "arch": arch, "created": created,
            "built_run": str(built_run), "repository": REPO,
            "targets": {n: {"tag": f"8.5-{n.split('-', 2)[2]}", "index": sha("1" if arch == "amd64" else "2"), "platform": sha("3")} for n in NAMES},
        }
        for arch in reuse_plan.ARCHES
    ]
    args = dict(sha=D, tree=TREE, inputs_hash=HASH, run_id=CI_RUN, ci_hash=CI_HASH)
    args.update(kw)
    return candidate.merge_records(records, targets(), args["sha"], args["tree"], args["inputs_hash"], args["run_id"], 1, ci_hash=args["ci_hash"])


class FakeApi:
    def __init__(self, runs=None, statuses=None, ext=None, artifacts=None, cand=None, fail=None):
        self.runs_ = [ci_run()] if runs is None else runs
        self.statuses_ = [status()] if statuses is None else statuses
        self.ext = ext_run() if ext is None else ext
        self.artifacts_ = artifacts if artifacts is not None else {
            "artifacts": [{"id": 9, "name": "release-candidate", "expired": False, "created_at": "2026-11-26T09:00:00Z"}]}
        self.cand = cand if cand is not None else make_candidate()
        self.fail = fail

    def _maybe(self, what):
        if self.fail == what:
            raise reuse_plan.NoReuse(f"GitHub API {what} failed: HTTP 502")

    def ci_runs(self, sha):
        self._maybe("ci_runs")
        return {"workflow_runs": self.runs_}

    def statuses(self, sha):
        self._maybe("statuses")
        return self.statuses_

    def run(self, run_id):
        self._maybe("run")
        return self.ext

    def artifacts(self, run_id):
        self._maybe("artifacts")
        return self.artifacts_

    def candidate(self, artifact_id):
        self._maybe("candidate")
        return self.cand


def decide(api=None, git=None, **kw):
    args = dict(mode="main", repo=SLUG, inputs_hash=HASH, ci_hash=CI_HASH, targets=targets(), dev_repo=REPO, hold="", head_sha="", now=NOW)
    args.update(kw)
    return release_source.decide(api or FakeApi(), git or FakeGit(), **args)


class TestCopy(unittest.TestCase):
    def test_a_tested_tree_identical_merge_copies(self):
        got = decide()
        self.assertEqual(got["mode"], "copy", got)
        self.assertEqual((got["sha"], got["run_id"], got["extended_run"], got["built_run"]), (D, str(CI_RUN), str(EXT_RUN), str(CI_RUN)))
        self.assertEqual(got["candidate"]["inputs_hash"], HASH)
        self.assertIn("ci run 700", got["reason"])

    def test_a_week_old_image_is_the_limit(self):
        self.assertEqual(decide(api=FakeApi(cand=make_candidate(created=stamp(timedelta(days=6, hours=23)))))["mode"], "copy")

    def test_the_newest_ci_run_decides(self):
        old_failed = ci_run(id=1, conclusion="failure", created_at="2026-11-25T08:00:00Z")
        self.assertEqual(decide(api=FakeApi(runs=[old_failed, ci_run()]))["mode"], "copy")


class TestRebuild(unittest.TestCase):
    def rebuild(self, reason, **kw):
        got = decide(**kw)
        self.assertEqual(got["mode"], "rebuild", got)
        self.assertIn(reason, got["reason"])
        self.assertNotIn("candidate", got)

    def test_a_single_parent(self):
        self.rebuild("1 parent(s)", git=FakeGit(parents=(FIRST,)))

    def test_an_octopus(self):
        self.rebuild("3 parent(s)", git=FakeGit(parents=(FIRST, D, "e" * 40)))

    def test_a_tree_mismatch(self):
        self.rebuild("changes the tree", git=FakeGit(trees={"HEAD": "a" * 40, D: TREE}))

    def test_a_hold(self):
        self.rebuild("RELEASE_HOLD is set (cve)", hold="cve")

    def test_a_blank_hold_does_not_hold(self):
        self.assertEqual(decide(hold="  \n")["mode"], "copy")

    def test_no_ci_run(self):
        self.rebuild("no develop push run", api=FakeApi(runs=[]))

    def test_a_ci_run_of_another_commit_or_event_or_branch(self):
        for bad in (ci_run(head_sha="e" * 40), ci_run(event="schedule"), ci_run(head_branch="main"), ci_run(path=".github/workflows/x.yml"),
                    ci_run(head_repository={"full_name": "evil/php"})):
            self.rebuild("no develop push run", api=FakeApi(runs=[bad]))

    def test_a_failed_run_is_not_a_success_even_when_images_passed(self):
        self.rebuild("completed/failure", api=FakeApi(runs=[ci_run(conclusion="failure")]))

    def test_a_run_still_going(self):
        self.rebuild("in_progress", api=FakeApi(runs=[ci_run(status="in_progress", conclusion=None)]))

    def test_a_newer_failed_rerun_wins(self):
        self.rebuild("failure", api=FakeApi(runs=[ci_run(), ci_run(id=701, conclusion="failure", created_at="2026-11-26T09:00:00Z")]))

    def test_no_extended_status(self):
        self.rebuild("no release/extended status", api=FakeApi(statuses=[status(context="other")]))
        self.rebuild("no extended.yml run of ci run 700.1", api=FakeApi(statuses=[]))

    def test_a_failed_extended_status(self):
        self.rebuild("is failure", api=FakeApi(statuses=[status(state="failure")]))

    def test_the_newest_extended_status_decides(self):
        old_ok = status(id=1, created_at="2026-11-26T09:00:00Z")
        new_bad = status(id=2, state="failure", created_at="2026-11-26T10:00:00Z")
        self.rebuild("is failure", api=FakeApi(statuses=[old_ok, new_bad]))
        self.assertEqual(decide(api=FakeApi(statuses=[status(id=2, state="failure", created_at="2026-11-26T08:00:00Z"), old_ok]))["mode"], "copy")

    def test_the_status_creator_and_text_prove_nothing(self):
        self.assertEqual(decide(api=FakeApi(statuses=[status(creator={"login": "mallory"}, description="whatever")]))["mode"], "copy")

    def test_a_forged_status_pointing_at_an_old_green_run(self):
        old = ext_run(id=5, display_title=f"extended {'e' * 40} ci 500.1")
        self.rebuild("is titled", api=FakeApi(ext=old, statuses=[status(target_url=f"https://github.com/{SLUG}/actions/runs/5")]))

    def test_a_status_pointing_outside_this_repository(self):
        self.rebuild("not a run of", api=FakeApi(statuses=[status(target_url=f"https://github.com/evil/php/actions/runs/{EXT_RUN}")]))
        self.rebuild("not a run of", api=FakeApi(statuses=[status(target_url="https://example.com/x")]))

    def test_a_status_whose_run_is_not_extended(self):
        self.rebuild("not an extended.yml run", api=FakeApi(ext=ext_run(path=".github/workflows/ci.yml")))
        self.rebuild("not an extended.yml run", api=FakeApi(ext=ext_run(path=".github/workflows/extended.yml@refs/heads/x")))

    def test_a_status_whose_run_is_another_run_than_it_names(self):
        self.rebuild("not a run of", api=FakeApi(ext=ext_run(id=1)))
        self.rebuild("not a run of", api=FakeApi(ext=ext_run(repository={"full_name": "evil/php"})))

    def test_an_extended_run_not_started_by_the_ci_completing(self):
        for event in ("workflow_dispatch", "push", "pull_request", "schedule", None):
            self.rebuild("not by the completion of the ci run", api=FakeApi(ext=ext_run(event=event)))

    def test_a_dispatch_from_a_branch_with_a_forged_title(self):
        # a dispatch input is free text, so its run-name can read exactly like the real one
        self.rebuild("not by the completion", api=FakeApi(ext=ext_run(event="workflow_dispatch", display_title=f"extended {D} ci {CI_RUN}.1")))

    def test_an_extended_run_of_another_commit_or_ci_run_or_attempt(self):
        for title in (f"extended {'e' * 40} ci {CI_RUN}.1", f"extended {D} ci 701.1", f"extended {D} ci {CI_RUN}.2",
                      f"extended {D}", f"extended {D} ci {CI_RUN}.1 ", None, ""):
            self.rebuild("is titled", api=FakeApi(ext=ext_run(display_title=title)))

    def test_a_ci_run_rerun_since_the_extended_run_started(self):
        self.rebuild("not 'extended %s ci %s.2'" % (D, CI_RUN), api=FakeApi(runs=[ci_run(run_attempt=2)]))
        self.assertEqual(decide(api=FakeApi(runs=[ci_run(run_attempt=2)], ext=ext_run(display_title=f"extended {D} ci {CI_RUN}.2")))["mode"], "copy")

    def test_a_ci_run_without_an_attempt(self):
        run = ci_run()
        del run["run_attempt"]
        self.rebuild("no run attempt", api=FakeApi(runs=[run]))

    def test_images_a_ci_run_reused_are_not_copied(self):
        self.rebuild("built by run(s) 600", api=FakeApi(cand=make_candidate(built_run=600)))

    def test_one_reused_architecture_is_enough_to_rebuild(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-cli"]["archs"]["arm64"]["built_run"] = "600"
        self.rebuild("600", api=FakeApi(cand=cand))
        cand = make_candidate()
        cand["built_run"] = "600"
        self.rebuild("600", api=FakeApi(cand=cand))

    def test_an_extended_run_that_did_not_succeed(self):
        self.rebuild("completed/failure", api=FakeApi(ext=ext_run(conclusion="failure")))
        self.rebuild("completed/cancelled", api=FakeApi(ext=ext_run(conclusion="cancelled")))

    def test_no_candidate_artifact(self):
        self.rebuild("left no release-candidate", api=FakeApi(artifacts={"artifacts": []}))

    def test_an_expired_candidate(self):
        doc = {"artifacts": [{"id": 9, "name": "release-candidate", "expired": True, "created_at": "2026-11-26T09:00:00Z"}]}
        self.rebuild("has expired", api=FakeApi(artifacts=doc))

    def test_a_stale_candidate(self):
        self.rebuild("8.0 days ago", api=FakeApi(cand=make_candidate(created=stamp(timedelta(days=8)))))

    def test_a_candidate_for_other_inputs(self):
        self.rebuild("inputs hash changed", api=FakeApi(cand=make_candidate(inputs_hash="b" * 64)))

    def test_a_ci_yml_that_changed(self):
        self.rebuild("ci.yml changed", api=FakeApi(cand=make_candidate(ci_hash="e" * 64)))

    def test_a_candidate_without_a_ci_hash(self):
        cand = make_candidate()
        del cand["ci_hash"]
        self.rebuild("ci.yml changed", api=FakeApi(cand=cand))

    def test_a_candidate_for_another_commit(self):
        self.rebuild("candidate names commit", api=FakeApi(cand=make_candidate(sha="e" * 40)))

    def test_a_candidate_for_another_tree(self):
        self.rebuild("candidate was written for tree", api=FakeApi(cand=make_candidate(tree="e" * 40)))

    def test_a_candidate_of_another_run(self):
        self.rebuild("it is an artifact of run", api=FakeApi(cand=make_candidate(run_id=701)))

    def test_a_candidate_missing_a_target(self):
        cand = make_candidate()
        del cand["targets"]["php-8_5-cli"]
        self.rebuild("php-8_5-cli is missing", api=FakeApi(cand=cand))

    def test_a_candidate_with_a_missing_arch(self):
        cand = make_candidate()
        del cand["targets"]["php-8_5-fpm"]["archs"]["arm64"]
        self.rebuild("php-8_5-fpm arm64 is missing", api=FakeApi(cand=cand))

    def test_an_api_error_never_fails_the_decision(self):
        for what in ("ci_runs", "statuses", "run", "artifacts", "candidate"):
            self.rebuild("GitHub API", api=FakeApi(fail=what))

    def test_an_unexpected_shape_is_a_rebuild(self):
        self.rebuild("unexpected shape", api=FakeApi(runs=[{"head_sha": D, "event": "push", "head_branch": "develop",
                                                             "path": "x/ci.yml", "head_repository": {"full_name": SLUG}}]))

    def test_git_failing(self):
        class Broken(FakeGit):
            def parents(self):
                raise release_source.NotCopy("git rev-list failed")
        self.rebuild("git rev-list failed", git=Broken())


class TestPromote(unittest.TestCase):
    def test_the_pr_head_is_the_second_parent(self):
        self.assertEqual(decide(mode="promote", head_sha=D)["mode"], "copy")

    def test_a_merge_ref_that_does_not_contain_the_pr_head(self):
        got = decide(mode="promote", head_sha="a" * 40)
        self.assertEqual(got["mode"], "rebuild")
        self.assertIn("is not the PR head", got["reason"])

    def test_a_merge_ref_whose_tree_is_not_the_heads(self):
        got = decide(mode="promote", head_sha=D, git=FakeGit(trees={"HEAD": "a" * 40, D: TREE}))
        self.assertIn("changes the tree", got["reason"])

    def test_a_hold_blocks_the_promotion(self):
        self.assertIn("RELEASE_HOLD", decide(mode="promote", head_sha=D, hold="1")["reason"])


class TestVerifyTarget(unittest.TestCase):
    def write(self, tmp, cand, bad=None):
        for arch in reuse_plan.ARCHES:
            slot = cand["targets"]["php-8_5-fpm"]["archs"][arch]
            (tmp / arch).write_text(slot["index"] + "\n")
            (tmp / f"{arch}.test-result.json").write_text(json.dumps({"platforms": [{"image_digest": slot["platform"]}]}))
        if bad:
            bad(tmp)

    def check(self, bad=None):
        cand = make_candidate()
        with tempfile.TemporaryDirectory() as tmp:
            self.write(Path(tmp), cand, bad)
            return release_source.verify_target(cand, "php-8_5-fpm", tmp)

    def test_matching_files(self):
        self.assertEqual(self.check(), [])

    def test_an_index_that_differs(self):
        self.assertIn("the artifact says index", self.check(lambda t: (t / "arm64").write_text(sha("9") + "\n"))[0])

    def test_a_platform_that_differs(self):
        bad = lambda t: (t / "amd64.test-result.json").write_text(json.dumps({"platforms": [{"image_digest": sha("9")}]}))  # noqa: E731
        self.assertIn("predicate is for platform", self.check(bad)[0])

    def test_a_predicate_without_a_platform(self):
        self.assertIn("no platform digest", self.check(lambda t: (t / "amd64.test-result.json").write_text("{}"))[0])

    def test_an_extra_file(self):
        self.assertIn("holds", self.check(lambda t: (t / "extra").write_text("x"))[0])

    def test_a_missing_arch(self):
        self.assertIn("holds", self.check(lambda t: (t / "arm64").unlink())[0])

    def test_the_age_is_rechecked_when_now_is_given(self):
        cand = make_candidate(created=stamp(timedelta(days=6, hours=23)))
        with tempfile.TemporaryDirectory() as tmp:
            self.write(Path(tmp), cand)
            self.assertEqual(release_source.verify_target(cand, "php-8_5-fpm", tmp, NOW), [])
            got = release_source.verify_target(cand, "php-8_5-fpm", tmp, NOW + timedelta(hours=2))
            self.assertIn("rebuild instead of copying", got[0])
            self.assertEqual(release_source.verify_target(cand, "php-8_5-fpm", tmp), [])

    def test_an_unreadable_creation_time_fails_closed(self):
        cand = make_candidate()
        cand["targets"]["php-8_5-cli"]["archs"]["amd64"]["created"] = "yesterday"
        self.assertIn("is not a UTC timestamp", release_source.verify_target(cand, "php-8_5-fpm", "/nonexistent", NOW)[0])
        del cand["targets"]
        self.assertIn("cannot read the creation times", release_source.verify_target(cand, "php-8_5-fpm", "/nonexistent", NOW)[0])

    def test_an_unknown_target(self):
        self.assertIn("no target", release_source.verify_target(make_candidate(), "php-9-fpm", "/nonexistent")[0])


class TestCli(unittest.TestCase):
    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = release_source.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_target_ok_and_failing(self):
        from unittest import mock
        cand = make_candidate()
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(release_source, "_now", lambda: NOW):
            tmp = Path(tmp)
            (tmp / "c.json").write_text(json.dumps(cand))
            d = tmp / "d"
            d.mkdir()
            TestVerifyTarget().write(d, cand)
            rc, out, _ = self.run_cli("target", "--candidate", str(tmp / "c.json"), "--target", "php-8_5-fpm", "--digests", str(d))
            self.assertEqual((rc, out.strip()), (0, "ok: php-8_5-fpm matches the candidate"))
            (d / "amd64").write_text(sha("9") + "\n")
            rc, _, err = self.run_cli("target", "--candidate", str(tmp / "c.json"), "--target", "php-8_5-fpm", "--digests", str(d))
            self.assertEqual(rc, 1)
            self.assertIn("FAIL", err)

    def test_target_refuses_a_candidate_that_aged_past_a_week(self):
        from unittest import mock
        cand = make_candidate()
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "c.json").write_text(json.dumps(cand))
            d = tmp / "d"
            d.mkdir()
            TestVerifyTarget().write(d, cand)
            argv = ("target", "--candidate", str(tmp / "c.json"), "--target", "php-8_5-fpm", "--digests", str(d))
            with mock.patch.object(release_source, "_now", lambda: NOW + timedelta(days=7)):
                rc, _, err = self.run_cli(*argv)
            self.assertEqual(rc, 1)
            self.assertIn("rebuild instead of copying", err)

    def test_decide_gate_fails_on_rebuild_and_saves_nothing(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "t.json").write_text(json.dumps(targets()))
            dest = tmp / "cand.json"
            argv = ["decide", "--mode", "promote", "--repo", SLUG, "--inputs-hash", HASH, "--ci-hash", CI_HASH, "--targets", str(tmp / "t.json"),
                    "--dev-repo", REPO, "--save-candidate", str(dest), "--gate", "--head-sha", D]
            with mock.patch.object(release_source, "ReleaseApi", lambda repo: FakeApi(statuses=[])), \
                    mock.patch.object(release_source, "Git", FakeGit):
                rc, out, err = self.run_cli(*argv)
            self.assertEqual(rc, 1)
            self.assertEqual(json.loads(out)["mode"], "rebuild")
            self.assertIn("FAIL: ", err)
            self.assertFalse(dest.exists())
            with mock.patch.object(release_source, "ReleaseApi", lambda repo: FakeApi()), mock.patch.object(release_source, "Git", FakeGit):
                rc, out, err = self.run_cli(*argv)
            self.assertEqual(rc, 0, err)
            self.assertEqual(json.loads(out)["mode"], "copy")
            self.assertNotIn("candidate", json.loads(out))
            self.assertEqual(json.loads(dest.read_text())["sha"], D)

    def test_main_mode_rebuild_exits_zero(self):
        from unittest import mock
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            (tmp / "t.json").write_text(json.dumps(targets()))
            argv = ["decide", "--mode", "main", "--repo", SLUG, "--inputs-hash", HASH, "--ci-hash", CI_HASH, "--targets", str(tmp / "t.json"),
                    "--dev-repo", REPO, "--save-candidate", str(tmp / "c.json"), "--hold", "x"]
            with mock.patch.object(release_source, "ReleaseApi", lambda repo: FakeApi()), mock.patch.object(release_source, "Git", FakeGit):
                rc, out, _ = self.run_cli(*argv)
            self.assertEqual(rc, 0)
            self.assertEqual(json.loads(out)["mode"], "rebuild")


class TestGit(unittest.TestCase):
    def test_a_failing_git_is_a_reason_not_a_crash(self):
        import subprocess

        def boom(*a, **k):
            raise subprocess.CalledProcessError(128, "git", stderr="fatal: bad object")
        with self.assertRaisesRegex(release_source.NotCopy, "bad object"):
            release_source.Git(run=boom).parents()


if __name__ == "__main__":
    unittest.main()
