"""ci/extended-plan.sh against a fake `docker` that answers `buildx imagetools inspect` for the
commit's own dev:<tag>-<sha12> images and/or the floating dev:<tag> ones. Covers the own-images
and floating branches and which of them count as the full selection."""
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

FAKE_DOCKER = r"""#!/usr/bin/env bash
[ "$1 $2 $3" = "buildx imagetools inspect" ] || { echo "fake docker: unexpected: $*" >&2; exit 2; }
ref="$4"
if [[ "$ref" =~ -[0-9a-f]{12}$ ]]; then
  [ "${FAKE_OWN:-}" = 1 ] || { echo "ERROR: $ref: not found" >&2; exit 1; }
else
  [ "${FAKE_FLOATING:-}" = 1 ] || { echo "ERROR: $ref: not found" >&2; exit 1; }
fi
printf '{"config":{"Labels":{"com.lotuswebagency.inputs-hash":"%s","org.opencontainers.image.revision":"%s"}}}\n' \
  "$FAKE_HASH" "$FAKE_REVISION"
"""


def sh(*args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()


class TestPlan(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.head = sh("git", "rev-parse", "HEAD")
        cls.tree_hash = sh("bash", "scripts/inputs-hash.sh")

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="extended-plan-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "bin"))
        docker = os.path.join(self.tmp, "bin", "docker")
        with open(docker, "w") as f:
            f.write(FAKE_DOCKER)
        os.chmod(docker, 0o755)
        self.out = os.path.join(self.tmp, "output")

    def plan(self, own=False, floating=False, **env):
        for k in ("EXT_RUN_SHA", "EXT_SHA_INPUT", "EXT_ONLY", "EXT_FLAVOR", "EXT_APPS", "EXT_BENCH",
                  "EXT_EVENT", "EXT_CANDIDATE", "EXT_CI_RUN"):
            os.environ.pop(k, None)
        env = {**os.environ, "PATH": os.path.join(self.tmp, "bin") + os.pathsep + os.environ["PATH"],
               "GITHUB_OUTPUT": self.out, "GITHUB_STEP_SUMMARY": os.devnull, "GITHUB_SHA": self.head,
               "FAKE_OWN": "1" if own else "", "FAKE_FLOATING": "1" if floating else "",
               "FAKE_HASH": self.tree_hash, "FAKE_REVISION": self.head, **env}
        r = subprocess.run(["bash", os.path.join(HERE, "extended-plan.sh")],
                           env=env, capture_output=True, text=True)
        outputs = {}
        if os.path.exists(self.out):
            with open(self.out) as f:
                outputs = dict(line.split("=", 1) for line in f.read().splitlines())
        return r, outputs

    def test_own_images_of_a_sha_with_the_default_selection_are_full(self):
        r, o = self.plan(own=True, EXT_SHA_INPUT=self.head)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("own images", r.stdout)
        self.assertEqual((o["own"], o["full"], o["apps"]), ("true", "true", "true"))
        self.assertEqual((o["sha"], o["checkout"]), (self.head, self.head))

    def test_a_narrowed_selection_of_own_images_is_not_full(self):
        for name, env in (("only", {"EXT_ONLY": "8.5"}), ("flavor", {"EXT_FLAVOR": "cli"}),
                          ("apps off", {"EXT_APPS": "false"})):
            with self.subTest(name):
                r, o = self.plan(own=True, EXT_SHA_INPUT=self.head, **env)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual((o["own"], o["full"]), ("true", "false"))

    def test_floating_images_are_never_own_or_full(self):
        r, o = self.plan(floating=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("floating images", r.stdout)
        self.assertEqual((o["own"], o["full"]), ("false", "false"))
        self.assertEqual((o["sha"], o["checkout"]), (self.head, self.head))

    def test_a_push_without_own_images_falls_back_to_the_floating_ones(self):
        r, o = self.plan(floating=True, EXT_EVENT="push", EXT_RUN_SHA=self.head)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("trying the floating images", r.stdout)
        self.assertEqual((o["own"], o["full"]), ("false", "false"))

    def test_a_push_with_own_images_uses_them(self):
        r, o = self.plan(own=True, floating=True, EXT_EVENT="push", EXT_RUN_SHA=self.head)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((o["own"], o["full"], o["checkout"]), ("true", "true", self.head))

    def test_a_dispatch_for_a_sha_without_images_fails(self):
        r, o = self.plan(floating=True, EXT_SHA_INPUT=self.head)
        self.assertEqual(r.returncode, 1)
        self.assertIn("cannot read", r.stderr)
        self.assertEqual(o, {})

    def test_floating_images_of_another_tree_are_refused(self):
        r, o = self.plan(floating=True, FAKE_HASH="0" * 64)
        self.assertEqual(r.returncode, 1)
        self.assertIn("inputs-hash", r.stderr)
        self.assertEqual(o, {})


if __name__ == "__main__":
    unittest.main()
