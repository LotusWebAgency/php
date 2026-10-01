import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MATRIX = ROOT / "matrix.json"
KEYS = ROOT / "php" / "release-keys.asc"

# "#   php-8.5.0    D95C...01A5  Daniel Scherzer (for PHP) <daniels@php.net>"
ROW = re.compile(r"^#\s+php-(\d+\.\d+\.\d+)\s+([0-9A-F]{40})\s+(\S.*)$")


def documented_rows():
    rows = {}
    for line in KEYS.read_text().splitlines():
        m = ROW.match(line)
        if m:
            rows[m.group(1)] = (m.group(2), m.group(3))
    return rows


class TestReleaseKeys(unittest.TestCase):
    """php/release-keys.asc must cover every release matrix.json names.

    This exists because it did not. Only 8.5 and 8.0 had ever been built, so
    only their signers were vendored, and the other nine versions died at the
    very first RUN of a twenty-minute build with "gpg: Can't check signature:
    No public key". The keyring is the one build input whose gaps cannot be
    found by reading it -- they only show up against a specific tarball -- so
    the mapping is written down and checked here instead.
    """

    def setUp(self):
        self.releases = {
            v["release"] for v in json.loads(MATRIX.read_text())["versions"].values()
        }
        self.rows = documented_rows()

    def test_the_table_parses_at_all(self):
        # A header reformat that breaks ROW would otherwise make every
        # assertion below vacuous: an empty table trivially has no missing
        # entries. Assert the measurement works before trusting it.
        self.assertGreater(len(self.rows), 0, "no release->fingerprint rows parsed "
                                              f"out of {KEYS}; the header format changed")

    def test_every_matrix_release_has_a_documented_signing_key(self):
        missing = sorted(self.releases - set(self.rows))
        self.assertEqual(missing, [], f"no signing key documented for {missing}")

    def test_no_documented_release_has_left_the_matrix(self):
        # The other direction of the same drift: a row for a release nothing
        # builds any more is stale documentation, and stale rows are how a
        # reader concludes a version is covered when it is not.
        extra = sorted(set(self.rows) - self.releases)
        self.assertEqual(extra, [], f"documented but not in matrix.json: {extra}")

    @unittest.skipIf(shutil.which("gpg") is None, "gpg not installed")
    def test_every_documented_fingerprint_is_actually_in_the_keyring(self):
        with tempfile.TemporaryDirectory() as home:
            Path(home).chmod(0o700)
            out = subprocess.run(
                ["gpg", "--homedir", home, "--batch", "--quiet",
                 "--import-options", "show-only", "--import",
                 "--with-colons", str(KEYS)],
                capture_output=True, text=True, check=True,
            ).stdout
        # Primary keys only. gpg --with-colons emits an fpr: record after
        # every pub: *and* every sub:, so collecting all of them means a row
        # documenting a subkey fingerprint -- or a typo that happens to collide
        # with one -- passes while the primary key it claims is absent. Track
        # which record type the fpr: belongs to instead.
        present = set()
        record = None
        for line in out.splitlines():
            kind = line.split(":", 1)[0]
            if kind in ("pub", "sub"):
                record = kind
            elif kind == "fpr" and record == "pub":
                present.add(line.split(":")[9])
                record = None
        # Positive control: a keyring that failed to parse yields an empty set,
        # which would make the loop below pass by finding nothing to contradict.
        self.assertGreater(len(present), 0, "gpg read no primary-key fingerprints out of the keyring")
        # Positive control for the narrowing itself: the keyring does contain
        # subkeys, so if the pub/sub tracking above ever broke open and
        # collected everything, this would stop being true.
        all_fprs = {l.split(":")[9] for l in out.splitlines() if l.startswith("fpr:")}
        self.assertGreater(len(all_fprs), len(present),
                           "no subkeys in the keyring, so this test cannot show it "
                           "distinguishes them -- the narrowing is unverified")
        for release, (fpr, signer) in sorted(self.rows.items()):
            self.assertIn(fpr, present,
                          f"{release} is documented as signed by {signer} ({fpr}) "
                          "but that key is not in this file")


if __name__ == "__main__":
    unittest.main()
