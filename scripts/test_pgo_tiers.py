import json
import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import pgo_tiers  # noqa: E402

LOCK = ROOT / "php" / "pgo" / "corpus.lock"
ROW = re.compile(r"^(\S+)\s+(\S+)\s+(\S+)\s+([0-9a-f]{64}|latest)\s+(\S+)$")


def lock_rows():
    for line in LOCK.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        yield ROW.match(line), line


class TestTiers(unittest.TestCase):
    def setUp(self):
        self.matrix, self.floors, self.rows = pgo_tiers.table()

    def test_every_pgo_version_lands_in_a_tier(self):
        """The check that catches a corpus which cannot run where it is reused."""
        for version, spec in self.matrix["versions"].items():
            if not spec.get("pgo"):
                continue
            floor = pgo_tiers.tier_of(version, self.floors)
            self.assertIsNotNone(floor, f"php {version} has pgo on but no tier covers it")
            self.assertLessEqual(pgo_tiers.key(floor), pgo_tiers.key(version))

    def test_every_opt_out_records_a_reason(self):
        for version, spec in self.matrix["versions"].items():
            if spec.get("pgo"):
                continue
            self.assertTrue(
                spec.get("pgo_disabled_reason", "").strip(),
                f"php {version} sets pgo false with no pgo_disabled_reason",
            )

    def test_membership_is_the_greatest_floor_at_or_below(self):
        self.assertEqual(pgo_tiers.tier_of("8.5", ["8.2", "8.1", "7.2"]), "8.2")
        self.assertEqual(pgo_tiers.tier_of("8.1", ["8.2", "8.1", "7.2"]), "8.1")
        self.assertEqual(pgo_tiers.tier_of("8.0", ["8.2", "8.1", "7.2"]), "7.2")
        self.assertIsNone(pgo_tiers.tier_of("7.0", ["8.2", "8.1", "7.2"]))

    def test_no_tier_is_empty(self):
        for floor, row in self.rows.items():
            self.assertTrue(row["versions"], f"tier {floor} serves nothing")

    def test_every_floor_is_a_matrix_version(self):
        for floor in self.floors:
            self.assertIn(floor, self.matrix["versions"])

    def test_control_version_is_below_the_floor(self):
        for floor in self.floors:
            out = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "pgo_tiers.py"), "control-of", floor],
                capture_output=True, text=True, check=True).stdout.strip()
            if out:
                self.assertLess(pgo_tiers.key(out), pgo_tiers.key(floor))


class TestCorpusLock(unittest.TestCase):
    def setUp(self):
        self.matrix, self.floors, self.rows = pgo_tiers.table()

    def test_every_row_parses(self):
        for match, line in lock_rows():
            self.assertIsNotNone(match, f"malformed row: {line}")

    def test_only_translation_packs_float(self):
        """`latest` is for the vendor's en-US pack alone, which upstream re-exports in place;
        fetch.sh refuses it on any other row, and so does this."""
        for match, line in lock_rows():
            if match and match.group(4) == "latest":
                self.assertEqual(match.group(2), "prestashop-lang", line)

    def test_every_row_names_a_declared_tier(self):
        """No wildcard tier, so a lookup cannot be shadowed by a broader row."""
        for match, line in lock_rows():
            self.assertIn(match.group(1), self.floors, line)

    def test_no_duplicate_tier_and_name(self):
        seen = set()
        for match, line in lock_rows():
            key = (match.group(1), match.group(2))
            self.assertNotIn(key, seen, f"duplicate row for {key}")
            seen.add(key)

    def test_every_tier_pins_every_artifact(self):
        want = {"laravel-app", "wordpress", "wp-sqlite", "prestashop"}
        have = {floor: set() for floor in self.floors}
        for match, _ in lock_rows():
            have[match.group(1)].add(match.group(2))
        for floor in self.floors:
            # prestashop-lang (task 29b): every tier except 7.0 prefetches the
            # vendor's own English translation pack, because the 1.7+/Symfony
            # install code calls out for it unconditionally (see corpus.lock's
            # header) -- 1.6.1.24 (the 7.0 row) predates that whole mechanism
            # and never makes the call, so it has nothing to pin here.
            tier_want = want | {"prestashop-lang"} if floor != "7.0" else want
            self.assertEqual(have[floor], tier_want, f"tier {floor} is missing pins")

    def test_urls_are_https_or_a_pinned_docker_image(self):
        """Every row still pins something fetchable by a verifiable hash.

        PrestaShop (task 29a) is not fetched over https at all -- its release
        zips live only on channels this build network cannot reach, so its
        rows pin the vendor's own Docker Hub image by immutable manifest
        digest instead (the same 64-hex sha256 column every other row uses,
        just verified by `docker pull ...@sha256:<digest>` rather than by
        downloading and hashing a file). A `docker://` URL is accepted here on
        the same footing as `https://`, not exempted from having one: the
        column still has to name a scheme and a location, so a row that pins
        nothing (a bare "unversioned" or similar) still fails this the same
        way it always did.
        """
        for match, line in lock_rows():
            url = match.group(5)
            ok = url.startswith("https://") or re.match(r"^docker://\S+/\S+:\S+$", url)
            self.assertTrue(ok, line)

    def composer_apps(self):
        """Corpus apps that install through Composer, i.e. that have per-tier manifests."""
        corpus = ROOT / "php" / "pgo" / "corpus"
        return sorted(d.name for d in corpus.iterdir()
                      if d.is_dir() and any(d.glob("*/composer.json")))

    def test_every_tier_has_a_manifest_for_every_composer_app(self):
        """Positive control for the platform check below.

        That check globs for manifests and asserts something about each one it
        finds. A tier with no manifests at all -- a floor added to corpus/tiers
        before its lockfiles exist, a directory renamed -- makes the glob empty,
        and an assertion with nothing to contradict it passes. This is the check
        that has something to contradict: every tier must have a manifest for
        every Composer app, so the loop below can never run zero times.
        """
        apps = self.composer_apps()
        self.assertTrue(apps, "no corpus app has per-tier composer manifests")
        corpus = ROOT / "php" / "pgo" / "corpus"
        for floor in self.floors:
            for app in apps:
                self.assertTrue(
                    (corpus / app / floor / "composer.json").is_file(),
                    f"{app} has no composer.json for tier {floor}",
                )

    def test_composer_platform_matches_the_tier_release(self):
        """The floor Composer resolved against has to be the tier's own release."""
        expected = len(self.composer_apps())
        for floor in self.floors:
            release = self.rows[floor]["release"]
            manifests = sorted((ROOT / "php" / "pgo" / "corpus").glob(f"*/{floor}/composer.json"))
            self.assertEqual(len(manifests), expected,
                             f"tier {floor} has {len(manifests)} manifests, expected {expected}")
            for manifest in manifests:
                platform = json.loads(manifest.read_text())["config"]["platform"]["php"]
                self.assertEqual(platform, release, f"{manifest} resolves against {platform}")


if __name__ == "__main__":
    unittest.main()
