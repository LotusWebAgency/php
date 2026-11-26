"""ci/extended_shards.py (the shard plan and the shard id resolver) and the way
ci/extended-run.sh acts on a shard id, against stub test scripts."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import extended_shards as sh  # noqa: E402

# (php, flavor, configs) as tests/apps/appsets.py cells reports them.
CELLS = (
    [("8.4", "fpm", 2)] * 7 + [("8.4", "cli", 1)] * 7 + [("8.4", "cli-builder", 1)] * 7   # 14 + 7 + 14 steps
    + [("7.3", "fpm", 2), ("7.3", "cli", 1)]                                             # 3 steps
    + [("8.0", "fpm", 2)] * 3                                                            # fpm only
)


class TestPlan(unittest.TestCase):
    def ids(self, **kw):
        kw.setdefault("flavors", [])
        kw.setdefault("apps", True)
        return [s["id"] for s in sh.plan(["7.3", "8.0", "8.4"], cells=CELLS, **kw)]

    def test_a_heavy_version_is_split_and_goes_first(self):
        self.assertEqual(self.ids(), ["8.4~cli", "8.4~fpm", "8.0", "7.3"])

    def test_the_fpm_shard_carries_the_extras_so_it_is_the_lighter_half_plus_them(self):
        by = {s["id"]: s["minutes"] for s in sh.plan(["8.4"], [], True, CELLS)}
        self.assertAlmostEqual(by["8.4~fpm"], sh.SETUP_MIN + 14 * sh.PER_STEP_MIN + sh.EXTRAS_MIN)
        self.assertAlmostEqual(by["8.4~cli"], sh.SETUP_MIN + 21 * sh.PER_STEP_MIN)

    def test_no_split_without_apps(self):
        self.assertEqual(self.ids(apps=False), ["7.3", "8.0", "8.4"])

    def test_no_split_when_only_one_half_has_suites(self):
        self.assertEqual(self.ids(flavors=["fpm"]), ["8.4", "8.0", "7.3"])
        self.assertEqual(self.ids(flavors=["cli", "cli-builder"]), ["8.4", "7.3", "8.0"])

    def test_threshold_is_configurable(self):
        self.assertEqual(self.ids(shard_min=1000), ["8.4", "8.0", "7.3"])
        self.assertEqual(self.ids(shard_min=1)[:2], ["8.4~cli", "8.4~fpm"])

    def test_every_shard_belongs_to_one_version_and_none_is_lost(self):
        shards = sh.plan(["7.3", "8.0", "8.4"], [], True, CELLS)
        self.assertEqual(sorted({s["version"] for s in shards}), ["7.3", "8.0", "8.4"])


class TestResolve(unittest.TestCase):
    def test_whole_version(self):
        self.assertEqual(sh.resolve("8.0", []), {"version": "8.0", "pull_flavor": "", "apps_flavor": "", "extras": "true"})

    def test_fpm_shard_pulls_everything_and_runs_fpm_suites(self):
        self.assertEqual(sh.resolve("8.4~fpm", []),
                         {"version": "8.4", "pull_flavor": "", "apps_flavor": "fpm", "extras": "true"})

    def test_cli_shard_pulls_only_its_flavors_and_has_no_extras(self):
        self.assertEqual(sh.resolve("8.4~cli", []),
                         {"version": "8.4", "pull_flavor": "cli,cli-builder", "apps_flavor": "cli,cli-builder", "extras": "false"})

    def test_flavor_selection_narrows_a_shard_and_may_empty_it(self):
        self.assertEqual(sh.resolve("8.4~cli", ["cli-builder"])["apps_flavor"], "cli-builder")
        with self.assertRaises(SystemExit):
            sh.resolve("8.4~cli", ["fpm"])

    def test_bad_ids(self):
        for bad in ("8.4~slow", "x.y~fpm"):
            with self.assertRaises((SystemExit, ValueError)):
                sh.resolve(bad, [])


STUB = r"""#!/usr/bin/env bash
echo "$(basename "$0") $*" >>"$STUB_CALLS"
"""


class TestExtendedRun(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="extended-run-test-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        for rel in ("ci/extended-run.sh", "ci/extended_shards.py"):
            os.makedirs(os.path.join(self.tmp, os.path.dirname(rel)), exist_ok=True)
            shutil.copy(os.path.join(HERE, os.path.basename(rel)), os.path.join(self.tmp, rel))
        for rel in ("tests/extended.sh", "tests/apps/run-matrix.sh"):
            path = os.path.join(self.tmp, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w") as f:
                f.write(STUB)
            os.chmod(path, 0o755)
        self.calls = os.path.join(self.tmp, "calls")
        self.logs = os.path.join(self.tmp, "logs")

    def run_step(self, only, name, sub, flavor=""):
        env = {**os.environ, "STUB_CALLS": self.calls, "EXT_LOG_ROOT": self.logs, "EXT_SHA": "a" * 40,
               "EXT_ONLY": only, "EXT_FLAVOR": flavor, "GITHUB_STEP_SUMMARY": os.devnull}
        r = subprocess.run(["bash", os.path.join(self.tmp, "ci/extended-run.sh"), name, sub],
                           env=env, capture_output=True, text=True)
        calls = []
        if os.path.exists(self.calls):
            with open(self.calls) as f:
                calls = f.read().splitlines()
        return r, calls

    def rows(self, name):
        with open(os.path.join(self.logs, name, "results.tsv")) as f:
            return f.read().splitlines()

    def test_a_plain_version_runs_as_before(self):
        r, calls = self.run_step("8.4", "pull", "pull")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(calls, ["extended.sh pull --only 8.4 --sha " + "a" * 40])

    def test_fpm_shard_pulls_all_flavors_and_runs_everything(self):
        _, calls = self.run_step("8.4~fpm", "pull", "pull")
        self.assertEqual(calls, ["extended.sh pull --only 8.4 --sha " + "a" * 40])
        os.remove(self.calls)
        _, calls = self.run_step("8.4~fpm", "ext-builder", "ext-builder")
        self.assertEqual(calls, ["extended.sh ext-builder --only 8.4", "extended.sh jit-stress --only 8.4"])

    def test_fpm_shard_runs_the_fpm_suites_only(self):
        _, calls = self.run_step("8.4~fpm", "apps", "apps")
        self.assertEqual(calls, ["extended.sh apps --only 8.4 --flavor fpm"])
        os.remove(self.calls)
        _, calls = self.run_step("8.4~fpm", "apps-prepare", "apps-prepare")
        self.assertEqual(calls, ["run-matrix.sh --prepare-only --only 8.4 --flavor fpm"])

    def test_cli_shard_pulls_its_flavors_and_skips_the_extras_with_rows(self):
        _, calls = self.run_step("8.4~cli", "pull", "pull")
        self.assertEqual(calls, ["extended.sh pull --only 8.4 --flavor cli,cli-builder --sha " + "a" * 40])
        os.remove(self.calls)
        for name in ("uarch", "ext-builder", "jit-stress"):
            r, calls = self.run_step("8.4~cli", name, name)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(calls, [], name + " must not run in the cli shard")
            self.assertTrue(self.rows(name)[0].startswith(f"{name}\t-\tSKIP\t0\t"), name)
        self.assertTrue(self.rows("jit-stress")[0].startswith("jit-stress\t-\tSKIP"))

    def test_cli_shard_runs_its_suites(self):
        _, calls = self.run_step("8.4~cli", "apps", "apps")
        self.assertEqual(calls, ["extended.sh apps --only 8.4 --flavor cli,cli-builder"])

    def test_a_bad_shard_id_fails(self):
        r, _ = self.run_step("8.4~slow", "pull", "pull")
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main()
