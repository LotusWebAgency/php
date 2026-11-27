"""ci/extended-status.sh against a fake `gh` that records its calls and returns what the
script's --jq filters would (the filters themselves are gh's, not tested here)."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SHA = "a" * 40

FAKE_GH = r"""#!/usr/bin/env bash
echo "$*" >>"$GH_CALLS"
case "$*" in
  *"/pulls?"*) cat "$GH_PRS" ;;
  *"/workflows/ci.yml/runs"*) cat "$GH_RUN" ;;
esac
"""


def needs(plan="success", own="true", full="true", sha=SHA, others=("success",), checkout=None):
    n = {"plan": {"result": plan, "outputs": {"sha": sha, "own": own, "full": full, "checkout": sha if checkout is None else checkout}}}
    for i, r in enumerate(others):
        n[f"job{i}"] = {"result": r}
    return json.dumps(n)


class TestStatus(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="extended-status-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "ci"))
        for f in ("extended-status.sh", "retry.sh"):
            shutil.copy(os.path.join(HERE, f), os.path.join(self.tmp, "ci", f))
        os.makedirs(os.path.join(self.tmp, "bin"))
        gh = os.path.join(self.tmp, "bin", "gh")
        with open(gh, "w") as f:
            f.write(FAKE_GH)
        os.chmod(gh, 0o755)
        self.calls = os.path.join(self.tmp, "calls")
        self.prs = os.path.join(self.tmp, "prs")
        self.run_file = os.path.join(self.tmp, "run")
        self.write(self.prs, "[]")
        self.write(self.run_file, "")

    def write(self, path, text):
        with open(path, "w") as f:
            f.write(text)

    def go(self, n, verdict="success", prs="[]", run=""):
        self.write(self.prs, prs)
        self.write(self.run_file, run)
        env = {**os.environ, "PATH": os.path.join(self.tmp, "bin") + os.pathsep + os.environ["PATH"],
               "GH_CALLS": self.calls, "GH_PRS": self.prs, "GH_RUN": self.run_file,
               "NEEDS_JSON": n, "EXT_VERDICT": verdict, "GITHUB_REPOSITORY": "Org/php",
               "GITHUB_RUN_ID": "42", "GITHUB_STEP_SUMMARY": os.devnull}
        r = subprocess.run(["bash", os.path.join(self.tmp, "ci/extended-status.sh")],
                           env=env, capture_output=True, text=True)
        calls = []
        if os.path.exists(self.calls):
            with open(self.calls) as f:
                calls = f.read().splitlines()
        return r, calls

    def posts(self, calls):
        return [c for c in calls if "/statuses/" in c]

    def test_success_posts_release_extended_on_the_planned_sha(self):
        r, calls = self.go(needs())
        self.assertEqual(r.returncode, 0, r.stderr)
        post = self.posts(calls)
        self.assertEqual(len(post), 1)
        self.assertIn(f"repos/Org/php/statuses/{SHA}", post[0])
        self.assertIn("state=success", post[0])
        self.assertIn("context=release/extended", post[0])
        self.assertIn("target_url=https://github.com/Org/php/actions/runs/42", post[0])

    def test_failure_posts_failure_and_touches_no_pr(self):
        r, calls = self.go(needs(), verdict="failure")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("state=failure", self.posts(calls)[0])
        self.assertFalse([c for c in calls if "pulls" in c])

    def test_no_status_for_a_subset_run_a_foreign_sha_or_a_failed_plan(self):
        for n in (needs(full="false"), needs(own="false"), needs(plan="failure"), needs(plan="skipped")):
            r, calls = self.go(n)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.posts(calls), [], n)
            if os.path.exists(self.calls):
                os.remove(self.calls)

    def test_no_status_when_the_tests_ran_from_another_tree(self):
        for checkout in ("b" * 40, ""):
            r, calls = self.go(needs(checkout=checkout))
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(self.posts(calls), [], checkout)
            self.assertEqual(calls, [])
            if os.path.exists(self.calls):
                os.remove(self.calls)

    def test_no_status_when_canceled_or_verdict_unknown(self):
        r, calls = self.go(needs(others=("success", "cancelled")))
        self.assertEqual(self.posts(calls), [])
        r, calls = self.go(needs(), verdict="cancelled")
        self.assertEqual(self.posts(calls), [])
        r, calls = self.go(needs(), verdict="skipped")
        self.assertEqual(self.posts(calls), [])

    def test_a_short_sha_is_refused(self):
        r, calls = self.go(needs(sha="abc123"))
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.posts(calls), [])

    def test_a_success_touches_nothing_but_the_status(self):
        r, calls = self.go(needs(), prs="[7]", run="900 completed failure")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(calls), 1, calls)
        self.assertEqual(len(self.posts(calls)), 1)


if __name__ == "__main__":
    unittest.main()
