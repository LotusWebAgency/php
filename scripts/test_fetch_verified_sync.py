import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CANONICAL = ROOT / "deps" / "fetch-verified.sh"
CORPUS_COPY = ROOT / "php" / "pgo" / "corpus" / "fetch-verified.sh"


class TestFetchVerifiedSync(unittest.TestCase):
    def test_corpus_copy_is_byte_identical_to_canonical(self):
        # php/pgo/Dockerfile.corpus builds with context php/pgo, which cannot
        # reach deps/ at the repo root, so the helper is duplicated in-tree.
        # This keeps the duplicate from drifting.
        self.assertEqual(
            CANONICAL.read_text(),
            CORPUS_COPY.read_text(),
            f"{CORPUS_COPY} has drifted from {CANONICAL} -- copy the canonical "
            "file over it",
        )

    def test_both_copies_are_executable(self):
        for path in (CANONICAL, CORPUS_COPY):
            self.assertTrue(path.stat().st_mode & 0o111, f"{path} is not executable")


class TestPhpSrcLock(unittest.TestCase):
    def test_every_release_has_two_64char_hex_hashes(self):
        lock = ROOT / "php" / "php-src.lock"
        rows = 0
        for line in lock.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            self.assertEqual(len(parts), 3, line)
            release, tar_sha, asc_sha = parts
            self.assertRegex(release, r"^\d+\.\d+\.\d+$")
            for sha in (tar_sha, asc_sha):
                self.assertEqual(len(sha), 64, sha)
                int(sha, 16)  # raises if not hex
            rows += 1
        self.assertGreater(rows, 0)

    def test_matrix_releases_all_have_a_lock_row(self):
        import json

        matrix = json.loads((ROOT / "matrix.json").read_text())
        releases = {v["release"] for v in matrix["versions"].values()}
        lock_releases = set()
        for line in (ROOT / "php" / "php-src.lock").read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            lock_releases.add(line.split()[0])
        self.assertEqual(releases, lock_releases)


if __name__ == "__main__":
    unittest.main()
