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

    def test_fifty_image_targets(self):
        self.assertEqual(len(self.targets), 50)

    def test_v3_only_for_84_and_85(self):
        v3 = {t["php"] for t in self.targets if t["uarch"] == "v3"}
        self.assertEqual(v3, {"8.4", "8.5"})

    def test_ext_builder_has_no_v3_variant(self):
        ext = [t for t in self.targets if t["flavor"] == "ext-builder"]
        self.assertEqual(len(ext), len(self.matrix["versions"]))
        self.assertEqual({t["uarch"] for t in ext}, {"baseline"})
        self.assertEqual({t["flavor"] for t in self.targets if t["uarch"] == "v3"},
                         {"fpm", "cli", "cli-builder"})

    def test_ext_builder_tags(self):
        t = next(t for t in self.targets if t["php"] == "8.5" and t["flavor"] == "ext-builder")
        self.assertEqual(t["name"], "php-8_5-ext-builder")
        self.assertEqual(t["tags"], ["lotuswebagency/php:8.5-ext-builder"])

    def test_pr_subset_names_exist(self):
        out = subprocess.run([sys.executable, str(GEN), "--github", "pr"],
                             capture_output=True, text=True, check=True).stdout
        names = {t["name"] for t in json.loads(out)["include"]}
        self.assertEqual(names, {"php-7_0-fpm", "php-8_2-fpm", "php-8_5-fpm",
                                 "php-8_5-cli-builder", "php-8_5-cli"})
        self.assertEqual(len(names), 5, "ext-builder rides with cli, so it adds no leg")

    def run_github(self, which):
        out = subprocess.run([sys.executable, str(GEN), "--github", which],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)["include"]

    def test_every_target_is_a_leg_or_exactly_one_riders(self):
        legs = self.run_github("build")
        covered = []
        for leg in legs:
            covered += leg["bake"].split()
            self.assertEqual(leg["bake"].split()[0], leg["name"])
        self.assertEqual(sorted(covered), sorted(t["name"] for t in self.targets))
        self.assertEqual(len(legs), 50 - len(self.matrix["versions"]))

    def test_ext_builder_rides_with_cli_not_alone(self):
        legs = self.run_github("build")
        self.assertNotIn("ext-builder", {leg["flavor"] for leg in legs})
        riding = [leg for leg in legs if leg["rider_name"]]
        self.assertEqual({leg["flavor"] for leg in riding}, {"cli"})
        self.assertEqual({leg["rider_flavor"] for leg in riding}, {"ext-builder"})
        self.assertEqual(len(riding), len(self.matrix["versions"]))
        for leg in riding:
            self.assertEqual(leg["uarch"], "baseline")
            self.assertEqual(leg["rider_name"], leg["name"].replace("-cli", "-ext-builder"))
            self.assertEqual(leg["rider_tag"], f"lotuswebagency/php:{leg['php']}-ext-builder")
            self.assertEqual(leg["bake"], f"{leg['name']} {leg['rider_name']}")

    def test_legs_without_a_rider_carry_empty_rider_strings(self):
        for leg in self.run_github("build"):
            if not leg["rider_name"]:
                self.assertEqual((leg["rider_flavor"], leg["rider_tag"], leg["bake"]),
                                 ("", "", leg["name"]))

    def test_rider_without_a_host_is_rejected(self):
        only_ext = [t for t in self.targets if t["name"] == "php-8_5-ext-builder"]
        with self.assertRaises(SystemExit):
            gen_matrix.build_legs(only_ext)

    def test_pr_subset_covers_every_flavor_incl_the_ext_builder_rider(self):
        legs = self.run_github("pr")
        baked = {n for leg in legs for n in leg["bake"].split()}
        self.assertIn("php-8_5-ext-builder", baked)
        self.assertEqual(baked, gen_matrix.PR_SUBSET)

    def test_every_version_has_four_flavors(self):
        for ver in self.matrix["versions"]:
            flavors = {t["flavor"] for t in self.targets
                       if t["php"] == ver and t["uarch"] == "baseline"}
            self.assertEqual(flavors, {"fpm", "cli", "cli-builder", "ext-builder"}, ver)

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
        """ext-builder shares its version's compile, so it adds no job."""
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


class TestValidateBaselineOnlyFlavors(unittest.TestCase):
    def test_current_matrix_is_valid(self):
        matrix = json.loads((ROOT / "matrix.json").read_text())
        gen_matrix.validate_baseline_only_flavors(matrix)  # must not raise

    def test_unknown_flavor_rejected(self):
        matrix = json.loads((ROOT / "matrix.json").read_text())
        matrix["baseline_only_flavors"] = ["nope"]
        with self.assertRaises(SystemExit):
            gen_matrix.validate_baseline_only_flavors(matrix)


class TestDrift(unittest.TestCase):
    def test_generated_file_is_in_sync(self):
        result = subprocess.run([sys.executable, str(GEN), "--check"],
                                 capture_output=True, text=True)
        self.assertEqual(result.returncode, 0,
                         f"matrix.gen.hcl is stale; run scripts/gen_matrix.py\n{result.stdout}{result.stderr}")


if __name__ == "__main__":
    unittest.main()
