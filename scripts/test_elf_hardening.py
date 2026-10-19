import os
import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tests" / "assert-elf-hardening.sh"
CFLAGS = ROOT / "php" / "cflags.sh"
LDFLAGS = ROOT / "php" / "ldflags.sh"

X86 = platform.machine() in ("x86_64", "AMD64")
# The flag that turns the code-level CET / branch-protection half off.
CF_OFF = ["-fcf-protection=none"] if X86 else ["-mbranch-protection=none"]

# Every function is exported (php exports the Zend API to its extensions and a
# module exports its entry points), writes a local array that escapes, and calls
# a fortified function; probe_big has a frame well over a page, which is what
# -fstack-clash-protection probes.
SRC = """
#include <stdio.h>
extern void sink(char *);
int probe_a(int n) { char buf[64]; snprintf(buf, sizeof buf, "%d", n); sink(buf); return buf[0]; }
int probe_b(int n) { char buf[64]; snprintf(buf, sizeof buf, "%x", n); sink(buf); return buf[1]; }
int probe_c(int n) { char buf[64]; snprintf(buf, sizeof buf, "%o", n); sink(buf); return buf[2]; }
int probe_big(int n) { char big[20000]; big[n % 100] = (char)n; sink(big); return big[(n + 1) % 100]; }
"""
SRC_EXE = SRC + "int main(void) { return probe_a(1) + probe_b(2) + probe_c(3) + probe_big(4); }\n"
SINK = "void sink(char *p) { (void)p; }\n"
# A correctly built small module that has nothing to show: no local array, and
# the only libc call copies a runtime-sized buffer, which fortify leaves plain.
SRC_TINY = """
#include <string.h>
int tiny(int a) { return a + 1; }
void tiny_copy(char *d, const char *s, unsigned long n) { memcpy(d, s, n); }
"""


def sh(*args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def have(tool):
    return shutil.which(tool) is not None


# clang builds the 8.5 line and gcc the rest; either proves the checker, so a
# host with only one of them still runs the suite.
CC = "clang" if have("clang") else "gcc"


@unittest.skipUnless(have(CC) and all(have(t) for t in ("readelf", "objdump")),
                     "needs a C compiler (clang or gcc), readelf and objdump")
class TestElfHardening(unittest.TestCase):
    """The negative control for tests/assert-elf-hardening.sh.

    The script asserts the shipped binaries carry PIE, full RELRO, BIND_NOW and
    a non-executable stack, and (--main, --code) the code-level properties: the
    canary, _FORTIFY_SOURCE, CET / branch-protection landing pads and stack
    probes. A checker that accepts everything would pass vacuously, so the same
    source is compiled with the project's real flags and, one property at a
    time, with that property switched off; the script must accept the first and
    reject each of the second with the message of the check that fired.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        (self.d / "probe.c").write_text(SRC)
        (self.d / "exe.c").write_text(SRC_EXE)
        (self.d / "sink.c").write_text(SINK)
        (self.d / "tiny.c").write_text(SRC_TINY)
        # cflags.sh guards its gcc-only flags on $COMPILER, so name the one in use.
        env = {**os.environ, "COMPILER": CC}
        self.cflags = sh("bash", str(CFLAGS), "baseline", env=env).stdout.split()
        self.ldflags = sh("bash", str(LDFLAGS)).stdout.split()

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, out, cflags, ldflags, src="probe.c"):
        r = sh(CC, "-shared", *cflags, *ldflags, "-o", str(self.d / out), str(self.d / src))
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.d / out

    def build_exe(self, out, cflags, ldflags):
        # -rdynamic: php exports the Zend API to its extensions, and the --main
        # landing-pad check reads those exports.
        r = sh(CC, *cflags, *ldflags, "-rdynamic", "-o", str(self.d / out),
               str(self.d / "exe.c"), str(self.d / "sink.c"))
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.d / out

    def check(self, *files, flags=(), env=None):
        e = dict(os.environ, **(env or {}))
        return sh("bash", str(SCRIPT), *flags, "unit", *[str(f) for f in files], env=e)

    def rejects(self, result, why, needle):
        out = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, why + " was accepted: " + out)
        self.assertIn(needle, out)

    # ---------------------------------------------------------------- link level

    def test_accepts_a_binary_built_with_the_projects_own_flags(self):
        so = self.build("hard.so", self.cflags, self.ldflags)
        r = self.check(so)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_rejects_partial_relro(self):
        # -z relro without -z now: GNU_RELRO is present but BIND_NOW is not, so
        # the GOT stays writable. Looks hardened at a glance.
        so = self.build("partial.so", self.cflags, ["-Wl,-z,relro"])
        self.rejects(self.check(so), "partial RELRO", "BIND_NOW")

    def test_rejects_an_executable_stack(self):
        so = self.build("execstack.so", self.cflags, self.ldflags + ["-Wl,-z,execstack"])
        self.rejects(self.check(so), "an executable stack", "executable stack")

    def test_rejects_a_non_pie_executable(self):
        # ET_EXEC loads at a fixed address, so ASLR does not apply to it. Every
        # other link property is on, so only the PIE check can be what fires.
        exe = self.build_exe("nopie", self.cflags, self.ldflags + ["-no-pie"])
        self.rejects(self.check(exe), "a non-PIE executable", "not ET_DYN")

    def test_accepts_a_pie_executable(self):
        exe = self.build_exe("pie", self.cflags, self.ldflags + ["-pie"])
        r = self.check(exe)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_rejects_a_file_that_is_not_an_elf(self):
        # A file readelf cannot parse must fail loudly, not yield empty output
        # that every grep reads as "absent".
        bad = self.d / "notanelf"
        bad.write_bytes(b"\x00\x01\x02not an elf at all\n" * 8)
        r = self.check(bad)
        self.assertNotEqual(r.returncode, 0, "a non-ELF file was accepted")

    def test_rejects_an_empty_file_list(self):
        r = sh("bash", str(SCRIPT), "unit")
        self.assertNotEqual(r.returncode, 0, "measuring nothing was accepted")
        self.assertIn("nothing was measured", r.stdout + r.stderr)

    # ------------------------------------------------- --main: the php binary

    def main_exe(self, name, extra):
        return self.build_exe(name, self.cflags + extra, self.ldflags + ["-pie"])

    def test_main_accepts_a_fully_hardened_executable(self):
        r = self.check(self.main_exe("main_ok", []), flags=["--main"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_main_rejects_a_build_without_the_stack_protector(self):
        exe = self.main_exe("main_nocanary", ["-fno-stack-protector"])
        self.rejects(self.check(exe, flags=["--main"]), "no stack protector", "__stack_chk_fail")

    def test_main_rejects_a_build_without_fortify(self):
        exe = self.main_exe("main_nofortify", ["-U_FORTIFY_SOURCE"])
        self.rejects(self.check(exe, flags=["--main"]), "no _FORTIFY_SOURCE", "_chk")

    def test_main_rejects_a_build_without_cet_or_branch_protection(self):
        # The distro's crt objects carry landing pads whatever our flags said, so
        # a bare "any endbr64 in the file" cannot see this; the exported
        # functions are the ones that must have them.
        exe = self.main_exe("main_nocf", CF_OFF)
        self.rejects(self.check(exe, flags=["--main"]), "no CET/branch protection", "exported functions start with")

    @unittest.skipUnless(X86, "the stack-probe signature is checked on x86-64 only")
    def test_main_rejects_a_build_without_stack_clash_protection(self):
        exe = self.main_exe("main_noprobe", ["-fno-stack-clash-protection"])
        self.rejects(self.check(exe, flags=["--main"]), "no stack-clash protection", "stack probes")

    # ------------------------------------- --code: every module, per file

    # The canary threshold is lowered so a module of a few lines is held to it;
    # at the default only 32 KiB of code is.
    STRICT = {"STACK_PROT_MIN_TEXT": "1"}

    def test_code_accepts_a_hardened_module(self):
        so = self.build("code_ok.so", self.cflags, self.ldflags)
        r = self.check(so, flags=["--code"], env=self.STRICT)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_code_rejects_a_module_without_the_stack_protector(self):
        so = self.build("code_nocanary.so", self.cflags + ["-fno-stack-protector"], self.ldflags)
        self.rejects(self.check(so, flags=["--code"], env=self.STRICT), "no stack protector", "__stack_chk_fail")

    def test_code_rejects_a_module_without_fortify(self):
        # snprintf is redirected to __snprintf_chk even for an unknown buffer, so
        # a plain snprintf import beside no _chk at all is a build without it.
        so = self.build("code_nofortify.so", self.cflags + ["-U_FORTIFY_SOURCE"], self.ldflags)
        self.rejects(self.check(so, flags=["--code"], env=self.STRICT), "no _FORTIFY_SOURCE", "_chk")

    def test_code_rejects_a_module_without_landing_pads(self):
        so = self.build("code_nocf.so", self.cflags + CF_OFF, self.ldflags)
        self.rejects(self.check(so, flags=["--code"], env=self.STRICT), "no landing pads", "landing pad")

    def test_code_does_not_fail_a_correct_small_module(self):
        # Nothing to canary, nothing for fortify to check, a plain memcpy of an
        # unknown size: the rule must not ask this file for what it cannot show.
        so = self.build("tiny.so", self.cflags, self.ldflags, src="tiny.c")
        r = self.check(so, flags=["--code"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_code_asks_a_small_module_for_landing_pads_regardless_of_size(self):
        so = self.build("tiny_nocf.so", self.cflags + CF_OFF, self.ldflags, src="tiny.c")
        self.rejects(self.check(so, flags=["--code"]), "a module without landing pads", "landing pad")


if __name__ == "__main__":
    unittest.main()
