import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / "deps" / "versions.lock"

ROW = re.compile(r"^(legacy|modern|both)\s+(\S+)\s+(\S+)\s+(\S+)\s+([0-9a-f]{64})\s+(\S+)$")


def rows():
    for line in LOCK.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        yield line


class TestLock(unittest.TestCase):
    def test_every_row_parses(self):
        for line in rows():
            self.assertRegex(line, ROW, f"malformed row: {line}")

    def test_every_sha_is_real(self):
        for line in rows():
            sha = ROW.match(line).group(5)
            self.assertNotIn("<", sha)
            self.assertEqual(len(sha), 64)

    def test_openssl_is_the_last_111_release(self):
        ssl = [ROW.match(l).groups() for l in rows() if ROW.match(l).group(2) == "openssl"]
        self.assertEqual(len(ssl), 1)
        self.assertEqual(ssl[0][2], "1.1.1w")

    def test_icu_split_across_eras(self):
        icu = sorted(ROW.match(l).group(3) for l in rows() if ROW.match(l).group(2) == "icu")
        self.assertEqual(icu, ["67.1", "70.1"])

    def test_urls_are_https(self):
        for line in rows():
            self.assertTrue(ROW.match(line).group(6).startswith("https://"), line)


if __name__ == "__main__":
    unittest.main()
