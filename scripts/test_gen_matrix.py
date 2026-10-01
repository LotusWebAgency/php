import json
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GEN = ROOT / "scripts" / "gen_matrix.py"

sys.path.insert(0, str(ROOT / "scripts"))
import gen_matrix  # noqa: E402


class TestTargets(unittest.TestCase):
    def setUp(self):
        self.matrix = json.loads((ROOT / "matrix.json").read_text())
        self.targets = gen_matrix.build_targets(self.matrix)

    def test_thirtynine_image_targets(self):
        self.assertEqual(len(self.targets), 39)

    def test_v3_only_for_84_and_85(self):
        v3 = {t["php"] for t in self.targets if t["uarch"] == "v3"}
        self.assertEqual(v3, {"8.4", "8.5"})

    def test_every_version_has_three_flavors(self):
        for ver in self.matrix["versions"]:
            flavors = {t["flavor"] for t in self.targets
                       if t["php"] == ver and t["uarch"] == "baseline"}
            self.assertEqual(flavors, {"fpm", "cli", "cli-builder"}, ver)

    def test_default_version_carries_aliases(self):
        default = self.matrix["default_version"]
        fpm = next(t for t in self.targets
                   if t["php"] == default and t["flavor"] == "fpm"
                   and t["uarch"] == "baseline")
        self.assertIn("lotuswebagency/php:latest", fpm["tags"])
        self.assertIn(f"lotuswebagency/php:{default}", fpm["tags"])

    def test_no_aliases_on_other_versions(self):
        others = [t for t in self.targets if t["php"] != self.matrix["default_version"]]
        for t in others:
            self.assertNotIn("lotuswebagency/php:latest", t["tags"], t["name"])

    def test_v3_tag_suffix(self):
        t = next(t for t in self.targets
                 if t["php"] == "8.5" and t["flavor"] == "fpm" and t["uarch"] == "v3")
        self.assertEqual(t["tags"], ["lotuswebagency/php:8.5-fpm-v3"])
        self.assertEqual(t["name"], "php-8_5-fpm-v3")

    def test_legacy_era_boundary(self):
        eras = {v: d["era"] for v, d in self.matrix["versions"].items()}
        self.assertEqual(eras["8.0"], "legacy")
        self.assertEqual(eras["8.1"], "modern")

    def test_every_target_names_a_corpus_image(self):
        for t in self.targets:
            self.assertTrue(t["corpus"], t["name"])
            self.assertTrue(t["corpus"].startswith("ghcr.io/"), t["corpus"])

    def test_corpus_is_the_greatest_floor_at_or_below_the_version(self):
        """Independent of pgo_tiers.tier_of, so the two have to agree."""
        floors = [line.split()[0] for line in
                  (ROOT / "php" / "pgo" / "corpus" / "tiers").read_text().splitlines()
                  if line.strip() and not line.strip().startswith("#")]
        key = lambda v: tuple(int(p) for p in v.split("."))  # noqa: E731
        for t in self.targets:
            want = max((f for f in floors if key(f) <= key(t["php"])), key=key)
            self.assertTrue(t["corpus"].endswith(f":php{want}"),
                            f'{t["name"]} php {t["php"]} got {t["corpus"]}, wanted the {want} tier')

    def test_corpus_is_named_even_when_pgo_is_off(self):
        """The Dockerfile mounts it unconditionally; a pgo=false target that
        named no corpus image would fail to build rather than fall back."""
        for t in self.targets:
            if t["pgo"] == "false":
                self.assertTrue(t["corpus"], t["name"])

    def test_compile_job_count_is_26(self):
        jobs = gen_matrix.build_compile_jobs(self.matrix)
        self.assertEqual(len(jobs), 26)

    def test_every_target_carries_support_fields(self):
        for t in self.targets:
            self.assertIn(t["support"], gen_matrix.VALID_SUPPORT, t["name"])
            self.assertRegex(t["eol_date"], r"^\d{4}-\d{2}-\d{2}$", t["name"])


class TestValidateSupportFields(unittest.TestCase):
    def setUp(self):
        self.matrix = json.loads((ROOT / "matrix.json").read_text())

    def test_current_matrix_is_valid(self):
        gen_matrix.validate_support_fields(self.matrix)  # must not raise

    def test_bad_support_value_rejected(self):
        self.matrix["versions"]["8.5"]["support"] = "not-a-status"
        with self.assertRaises(SystemExit):
            gen_matrix.validate_support_fields(self.matrix)

    def test_bad_eol_date_rejected(self):
        self.matrix["versions"]["8.5"]["eol_date"] = "31 Dec 2029"
        with self.assertRaises(SystemExit):
            gen_matrix.validate_support_fields(self.matrix)


class TestDrift(unittest.TestCase):
    def test_generated_file_is_in_sync(self):
        result = subprocess.run([sys.executable, str(GEN), "--check"],
                                 capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         f"matrix.gen.hcl is stale; run scripts/gen_matrix.py\n{result.stdout}{result.stderr}")


if __name__ == "__main__":
    unittest.main()
