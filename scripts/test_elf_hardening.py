import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tests" / "assert-elf-hardening.sh"
CFLAGS = ROOT / "php" / "cflags.sh"
LDFLAGS = ROOT / "php" / "ldflags.sh"

SRC = "int probe_fn(int n) { char buf[64]; __builtin_memset(buf, n, sizeof buf); return buf[0]; }\n"


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def have(tool):
    return shutil.which(tool) is not None


@unittest.skipUnless(all(have(t) for t in ("clang", "readelf", "objdump")),
                     "needs clang, readelf and objdump")
class TestElfHardening(unittest.TestCase):
    """The negative control for tests/assert-elf-hardening.sh.

    That script asserts the shipped binaries carry PIE, full RELRO, BIND_NOW and
    a non-executable stack. Those are positive assertions, so they cannot pass
    by accident -- but nothing so far proved they can *fail*, and a checker that
    accepts everything is exactly the kind of vacuous green this project keeps
    finding. So: compile the same source twice, once with the project's real
    flags and once deliberately unhardened, and require the script to accept the
    first and reject the second.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        (self.d / "probe.c").write_text(SRC)
        self.cflags = sh("bash", str(CFLAGS), "baseline").stdout.split()
        self.ldflags = sh("bash", str(LDFLAGS)).stdout.split()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, out, cflags, ldflags):
        r = sh("clang", "-shared", *cflags, *ldflags, "-o", str(self.d / out), str(self.d / "probe.c"))
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.d / out

    def check(self, *files):
        return sh("bash", str(SCRIPT), "unit", *[str(f) for f in files])

    def test_accepts_a_binary_built_with_the_projects_own_flags(self):
        so = self.build("hard.so", self.cflags, self.ldflags)
        r = self.check(so)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_rejects_partial_relro(self):
        # -z relro without -z now: the GNU_RELRO segment is there, BIND_NOW is
        # not, and the GOT stays writable. This is the failure mode most likely
        # to appear for real -- it looks hardened at a glance.
        so = self.build("partial.so", self.cflags, ["-Wl,-z,relro"])
        r = self.check(so)
        self.assertNotEqual(r.returncode, 0, "partial RELRO was accepted")
        self.assertIn("BIND_NOW", r.stdout + r.stderr)

    def test_rejects_an_executable_stack(self):
        so = self.build("execstack.so", self.cflags, self.ldflags + ["-Wl,-z,execstack"])
        r = self.check(so)
        self.assertNotEqual(r.returncode, 0, "an executable stack was accepted")
        self.assertIn("executable stack", r.stdout + r.stderr)

    def test_rejects_a_file_that_is_not_an_elf(self):
        # The measurement-failure guard: a file readelf cannot parse must fail
        # loudly, not produce empty output that every grep reads as "absent".
        bad = self.d / "notanelf"
        bad.write_bytes(b"\x00\x01\x02not an elf at all\n" * 8)
        r = self.check(bad)
        self.assertNotEqual(r.returncode, 0, "a non-ELF file was accepted")

    def test_rejects_an_empty_file_list(self):
        r = sh("bash", str(SCRIPT), "unit")
        self.assertNotEqual(r.returncode, 0, "measuring nothing was accepted")
        self.assertIn("nothing was measured", r.stdout + r.stderr)


if __name__ == "__main__":
    unittest.main()
