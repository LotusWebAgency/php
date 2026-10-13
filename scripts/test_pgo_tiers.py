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
CORPUS = ROOT / "php" / "pgo" / "corpus"

# What each corpus app fetches through corpus.lock. Symfony and Drupal fetch
# nothing there: their composer.lock pins every package. prestashop-lang, which
# every PrestaShop tier but 7.0 adds, is handled where this map is used. A tier
# naming an app missing from this map fails, so a new app must say how it is
# pinned.
LOCK_ARTIFACTS = {
    "laravel": {"laravel-app"},
    "symfony": set(),
    "wordpress": {"wordpress", "wp-sqlite"},
    "prestashop": {"prestashop"},
    "drupal": set(),
}


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
        self.assertEqual(pgo_tiers.tier_of("8.5", ["8.5", "8.4", "8.2"]), "8.5")
        self.assertEqual(pgo_tiers.tier_of("8.3", ["8.5", "8.4", "8.2"]), "8.2")
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

    def test_expected_floors(self):
        """Seven tiers, with 8.4 and 8.5 on their own."""
        self.assertEqual(self.floors, ["8.5", "8.4", "8.2", "8.1", "7.2", "7.1", "7.0"])
        self.assertEqual(pgo_tiers.tier_of("8.3", self.floors), "8.2")
        self.assertEqual(pgo_tiers.tier_of("8.0", self.floors), "7.2")

    def test_apps_of_reads_the_tiers_file(self):
        for floor in self.floors:
            apps = pgo_tiers.apps_of(floor)
            self.assertTrue(apps, f"tier {floor} names no apps")
            self.assertEqual(len(apps), len(set(apps)), f"tier {floor} lists an app twice")
            out = subprocess.run(
                [sys.executable, str(ROOT / "scripts" / "pgo_tiers.py"), "apps-of", floor],
                capture_output=True, text=True, check=True).stdout.split()
            self.assertEqual(out, apps)
        self.assertIsNone(pgo_tiers.apps_of("9.9"))

    def test_expected_apps(self):
        """Drupal 11.4.8 and Mage-OS 3.5.0 train the 8.4 and 8.5 tiers only.

        Every tier trains the four base apps; the two CMS apps are on exactly
        those two tiers, not "from 8.4 up", so a new tier or a renamed floor
        cannot pick them up by accident.
        """
        base = {"laravel", "symfony", "wordpress", "prestashop"}
        for floor in self.floors:
            self.assertTrue(base <= set(pgo_tiers.apps_of(floor)), f"tier {floor} lacks a base app")
        # Mage-OS may be absent from corpus/tiers; if present it must be on exactly those two tiers.
        for app, required in (("drupal", True), ("mageos", False)):
            on = sorted(f for f in self.floors if app in pgo_tiers.apps_of(f))
            if required:
                self.assertEqual(on, ["8.4", "8.5"], f"{app} must train the 8.4 and 8.5 tiers and no other")
            else:
                self.assertIn(on, ([], ["8.4", "8.5"]), f"{app} must train the 8.4 and 8.5 tiers only")
        extras = {app for f in self.floors for app in pgo_tiers.apps_of(f)} - base - {"drupal", "mageos"}
        self.assertFalse(extras, f"apps outside the expected set: {sorted(extras)}")


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
        """A tier pins what its own apps fetch, and nothing else.

        The expectation is derived from the tier's line in corpus/tiers through
        the app -> artifact map, and compared for equality, so it fails both
        ways: an app without its pins, and pins for an app the tier does not
        train (Drupal's below 8.4, say, or Mage-OS's).
        """
        have = {floor: set() for floor in self.floors}
        for match, _ in lock_rows():
            have[match.group(1)].add(match.group(2))
        for floor in self.floors:
            apps = pgo_tiers.apps_of(floor)
            want = set()
            for app in apps:
                self.assertIn(app, LOCK_ARTIFACTS,
                              f"tier {floor} trains {app}, which LOCK_ARTIFACTS does not say how it is pinned")
                want |= LOCK_ARTIFACTS[app]
            # Every tier except 7.0 prefetches the vendor's English translation
            # pack, which the 1.7+/Symfony installer fetches unconditionally (see
            # corpus.lock's header); PrestaShop 1.6.1.24 (the 7.0 tier) never does.
            if "prestashop" in apps and floor != "7.0":
                want.add("prestashop-lang")
            self.assertEqual(have[floor], want,
                             f"tier {floor}: pins in corpus.lock differ from what its apps need "
                             f"(missing {sorted(want - have[floor])}, unexpected {sorted(have[floor] - want)})")

    def test_urls_are_https_or_a_pinned_docker_image(self):
        """Every row pins something fetchable by a verifiable hash.

        PrestaShop's release zips are not reachable from the build network, so
        its rows pin the vendor's Docker Hub image by immutable manifest digest
        (the same 64-hex column, verified by `docker pull ...@sha256:<digest>`).
        A `docker://` URL is accepted like `https://`; a row naming no scheme
        and location still fails.
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

    def tier_composer_apps(self, floor):
        """The Composer apps this tier trains: its line in corpus/tiers, intersected."""
        return sorted(set(pgo_tiers.apps_of(floor)) & set(self.composer_apps()))

    def test_every_tier_has_a_manifest_for_every_composer_app(self):
        """Positive control for the platform check below.

        That check globs for manifests, so a tier with none (a floor added
        before its lockfiles exist, a renamed directory) would pass vacuously.
        Every tier must have a manifest for every Composer app it trains, and an
        app not on the tier's line must have no <app>/<tier>/ directory.
        """
        apps = self.composer_apps()
        self.assertTrue(apps, "no corpus app has per-tier composer manifests")
        every_app = sorted(d.name for d in CORPUS.iterdir() if d.is_dir())
        for floor in self.floors:
            trained = self.tier_composer_apps(floor)
            self.assertTrue(trained, f"tier {floor} trains no Composer app")
            for app in trained:
                self.assertTrue(
                    (CORPUS / app / floor / "composer.json").is_file(),
                    f"{app} has no composer.json for tier {floor}",
                )
                self.assertTrue(
                    (CORPUS / app / floor / "composer.lock").is_file(),
                    f"{app} has no composer.lock for tier {floor}",
                )
            for app in every_app:
                if app in pgo_tiers.apps_of(floor):
                    continue
                self.assertFalse(
                    (CORPUS / app / floor).exists(),
                    f"corpus/{app}/{floor}/ exists but tier {floor} does not train {app}",
                )

    def test_every_composer_app_belongs_to_a_tier(self):
        """A Composer app no tier lists is dead weight in the build context."""
        listed = {app for floor in self.floors for app in pgo_tiers.apps_of(floor)}
        for app in self.composer_apps():
            self.assertIn(app, listed, f"corpus/{app} has manifests but no tier trains it")
        for floor in self.floors:
            for app in pgo_tiers.apps_of(floor):
                self.assertTrue((CORPUS / app / "endpoints").is_file(),
                                f"tier {floor} trains {app}, which has no corpus/{app}/endpoints")

    def test_composer_platform_matches_the_tier_release(self):
        """The floor Composer resolved against has to be the tier's own release."""
        for floor in self.floors:
            expected = len(self.tier_composer_apps(floor))
            release = self.rows[floor]["release"]
            manifests = sorted(CORPUS.glob(f"*/{floor}/composer.json"))
            self.assertEqual(len(manifests), expected,
                             f"tier {floor} has {len(manifests)} manifests, expected {expected}")
            for manifest in manifests:
                platform = json.loads(manifest.read_text())["config"]["platform"]["php"]
                self.assertEqual(platform, release, f"{manifest} resolves against {platform}")


if __name__ == "__main__":
    unittest.main()
