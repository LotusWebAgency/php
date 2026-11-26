"""ci/verify-pin.sh against a fake `docker buildx imagetools inspect --raw`."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INDEX = "sha256:" + "1" * 64
AMD = "sha256:" + "a" * 64
ARM = "sha256:" + "b" * 64
ATT = "sha256:" + "c" * 64
RAW = {"manifests": [
    {"digest": AMD, "platform": {"os": "linux", "architecture": "amd64"}},
    {"digest": ARM, "platform": {"os": "linux", "architecture": "arm64"}},
    {"digest": ATT, "platform": {"os": "unknown", "architecture": "unknown"}},
]}
FAKE_DOCKER = r"""#!/usr/bin/env bash
echo "$*" >>"$DOCKER_CALLS"
if [ -n "${DOCKER_FAIL:-}" ]; then echo "$DOCKER_FAIL" >&2; exit 1; fi
cat "$DOCKER_RAW"
"""


class TestVerifyPin(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="verify-pin-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        os.makedirs(os.path.join(self.tmp, "ci"))
        for f in ("verify-pin.sh", "platform-digest.sh", "retry.sh"):
            shutil.copy(os.path.join(HERE, f), os.path.join(self.tmp, "ci", f))
        os.makedirs(os.path.join(self.tmp, "bin"))
        docker = os.path.join(self.tmp, "bin", "docker")
        with open(docker, "w") as f:
            f.write(FAKE_DOCKER)
        os.chmod(docker, 0o755)
        self.raw = os.path.join(self.tmp, "raw.json")
        self.calls = os.path.join(self.tmp, "calls")
        with open(self.raw, "w") as f:
            json.dump(RAW, f)

    def go(self, ref, arch, want, fail=""):
        env = {**os.environ, "PATH": os.path.join(self.tmp, "bin") + os.pathsep + os.environ["PATH"],
               "DOCKER_RAW": self.raw, "DOCKER_CALLS": self.calls, "DOCKER_FAIL": fail}
        return subprocess.run(["bash", os.path.join(self.tmp, "ci/verify-pin.sh"), ref, arch, want],
                              env=env, capture_output=True, text=True)

    def test_the_recorded_platform_passes(self):
        for arch, want in (("amd64", AMD), ("arm64", ARM)):
            r = self.go(f"r.io/dev@{INDEX}", arch, want)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(want, r.stdout)
        with open(self.calls) as f:
            self.assertIn(f"buildx imagetools inspect r.io/dev@{INDEX} --raw", f.read())

    def test_another_platform_digest_fails(self):
        r = self.go(f"r.io/dev@{INDEX}", "amd64", ARM)
        self.assertEqual(r.returncode, 1)
        self.assertIn(f"is platform {AMD}, the candidate recorded {ARM}", r.stderr)

    def test_an_index_without_the_arch_fails(self):
        with open(self.raw, "w") as f:
            json.dump({"manifests": [RAW["manifests"][0]]}, f)
        r = self.go(f"r.io/dev@{INDEX}", "arm64", ARM)
        self.assertEqual(r.returncode, 1)
        self.assertIn("expected exactly one linux/arm64 manifest", r.stderr)

    def test_a_tag_reference_or_a_malformed_digest_is_refused(self):
        self.assertEqual(self.go("r.io/dev:8.5-fpm-abc", "amd64", AMD).returncode, 1)
        self.assertEqual(self.go(f"r.io/dev@{INDEX}", "amd64", "sha256:short").returncode, 1)
        self.assertFalse(os.path.exists(self.calls))

    def test_a_missing_manifest_fails(self):
        r = self.go(f"r.io/dev@{INDEX}", "amd64", AMD, fail="ERROR: manifest unknown")
        self.assertEqual(r.returncode, 1)
        self.assertIn("manifest unknown", r.stderr)


if __name__ == "__main__":
    unittest.main()
