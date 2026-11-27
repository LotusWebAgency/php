"""ci/verify-revision.sh against a scratch repository: a reuse commit's label passes, a wrong one fails."""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


class TestVerifyRevision(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="verify-revision-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "ci"))
        shutil.copy(os.path.join(HERE, "verify-revision.sh"), os.path.join(self.tmp, "ci", "verify-revision.sh"))
        self.git("init", "-q", "-b", "develop")
        self.write("php/a.txt", "a")
        self.write("scripts/test_x.py", "t")
        self.d = self.commit("D")

    def git(self, *args):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com"}
        return subprocess.run(["git", "-c", "commit.gpgsign=false", *args], cwd=self.tmp, env=env,
                              capture_output=True, text=True, check=True).stdout.strip()

    def write(self, path, text):
        full = os.path.join(self.tmp, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w") as f:
            f.write(text)

    def commit(self, msg):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", msg)
        return self.git("rev-parse", "HEAD")

    def verify(self, rev, want):
        return subprocess.run(["bash", os.path.join(self.tmp, "ci", "verify-revision.sh"), rev, want],
                              capture_output=True, text=True)

    def test_the_commit_itself_passes(self):
        self.assertEqual(self.verify(self.d, self.d).returncode, 0)

    def test_an_ancestor_whose_build_inputs_are_identical_passes(self):
        self.write("tests/extended.sh", "changed")
        self.write("scripts/test_x.py", "changed")
        self.write("ci/other.sh", "changed")
        e = self.commit("E: tests, ci and unit tests only")
        r = self.verify(self.d, e)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_an_ancestor_with_other_build_inputs_fails(self):
        self.write("php/a.txt", "b")
        e = self.commit("E: an input changed")
        r = self.verify(self.d, e)
        self.assertEqual(r.returncode, 1)
        self.assertIn("build inputs differ", r.stderr)

    def test_a_commit_that_is_not_an_ancestor_fails_even_with_identical_inputs(self):
        self.git("checkout", "-q", "-b", "other")
        self.write("tests/x.sh", "x")
        other = self.commit("other lineage")
        self.git("checkout", "-q", "develop")
        self.write("tests/y.sh", "y")
        e = self.commit("E")
        r = self.verify(other, e)
        self.assertEqual(r.returncode, 1)
        self.assertIn("not an ancestor", r.stderr)

    def test_a_descendant_label_fails(self):
        self.write("tests/y.sh", "y")
        e = self.commit("E")
        self.assertEqual(self.verify(e, self.d).returncode, 1)

    def test_a_revision_missing_from_the_history_fails(self):
        self.assertIn("not in this repository", self.verify("1" * 40, self.d).stderr)

    def test_a_label_that_is_not_a_full_sha_fails(self):
        for rev in ("", "main", self.d[:12]):
            self.assertEqual(self.verify(rev, self.d).returncode, 1, rev)

    def test_the_path_list_is_the_one_inputs_hash_hashes(self):
        def lists(path):
            text = Path(path).read_text()
            return (re.search(r"^PATHS=\((.*)\)$", text, re.M).group(1),
                    re.search(r"^EXCLUDE=\((.*)\)$", text, re.M).group(1))
        self.assertEqual(lists(os.path.join(HERE, "verify-revision.sh")),
                         lists(os.path.join(ROOT, "scripts", "inputs-hash.sh")))


if __name__ == "__main__":
    unittest.main()
