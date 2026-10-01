import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(script, *args):
    out = subprocess.run(["bash", str(ROOT / script), *args],
                         capture_output=True, text=True, check=True)
    return out.stdout.strip()


class TestCflags(unittest.TestCase):
    def test_hardening_flags_always_present(self):
        flags = run("php/cflags.sh", "baseline")
        for expected in ("-fstack-protector-strong", "-fstack-clash-protection",
                         "-D_FORTIFY_SOURCE=3", "-fPIC"):
            self.assertIn(expected, flags)

    def test_fortify_is_undefined_first(self):
        # the base image may already define it; redefining without -U warns and may not apply
        flags = run("php/cflags.sh", "baseline")
        self.assertIn("-U_FORTIFY_SOURCE", flags)
        self.assertLess(flags.index("-U_FORTIFY_SOURCE"), flags.index("-D_FORTIFY_SOURCE=3"))

    def test_baseline_and_v3_differ(self):
        self.assertNotEqual(run("php/cflags.sh", "baseline"), run("php/cflags.sh", "v3"))

    def test_v3_sets_a_march(self):
        flags = run("php/cflags.sh", "v3")
        self.assertTrue("-march=x86-64-v3" in flags or "-march=armv8.2-a+crypto" in flags)

    def test_arch_specific_cfi_flag(self):
        flags = run("php/cflags.sh", "baseline")
        self.assertTrue("-fcf-protection=full" in flags or "-mbranch-protection=standard" in flags)


class TestLdflags(unittest.TestCase):
    def test_full_relro_and_noexecstack(self):
        flags = run("php/ldflags.sh")
        self.assertIn("-Wl,-z,relro", flags)
        self.assertIn("-Wl,-z,now", flags)
        self.assertIn("-Wl,-z,noexecstack", flags)
        self.assertIn("-Wl,--as-needed", flags)

    def test_no_prefix_emits_no_rpath(self):
        flags = run("php/ldflags.sh")
        self.assertNotIn("rpath", flags)

    def test_prefix_emits_rpath_for_that_prefix(self):
        # global LD_LIBRARY_PATH made a vendored libcurl shadow debian's for every
        # process in the image (task 1); rpath binds the search path to the binary.
        flags = run("php/ldflags.sh", "/opt/php-deps")
        self.assertIn("-Wl,-rpath,/opt/php-deps/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/php-deps/lib", flags)

    def test_multiple_prefixes_each_emit_rpath(self):
        # task 8: /opt/imagemagick (all eras) and /opt/php-deps (legacy, task 14)
        # both need to be on the search path of the same binary.
        flags = run("php/ldflags.sh", "/opt/imagemagick", "/opt/php-deps")
        self.assertIn("-Wl,-rpath,/opt/imagemagick/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/imagemagick/lib", flags)
        self.assertIn("-Wl,-rpath,/opt/php-deps/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/php-deps/lib", flags)


class TestRuntimeLibs(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc") and shutil.which("dpkg"),
                          "requires gcc to build the test fixture and dpkg to resolve ownership")
    def test_mixed_owned_and_unowned_libraries(self):
        # one dependency resolves to a real debian package (libc6); the other
        # resolves via rpath to a scratch-built .so that belongs to no package
        # (standing in for the legacy era's vendored /opt/php-deps/lib). dpkg -S
        # must not blow up the whole script under set -euo pipefail because of it.
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            vendor = td / "vendor"
            vendor.mkdir()
            tree = td / "tree" / "bin"
            tree.mkdir(parents=True)

            lib_src = td / "lib.c"
            lib_src.write_text("int unowned_fn(void) { return 42; }\n")
            subprocess.run(
                ["gcc", "-shared", "-fPIC", "-Wl,-soname,libunowned.so.1",
                 "-o", str(vendor / "libunowned.so.1"), str(lib_src)],
                check=True, capture_output=True,
            )

            prog_src = td / "prog.c"
            prog_src.write_text(
                "extern int unowned_fn(void);\n"
                "int main(void) { return unowned_fn() == 42 ? 0 : 1; }\n"
            )
            subprocess.run(
                ["gcc", "-o", str(tree / "prog"), str(prog_src),
                 "-L" + str(vendor), "-l:libunowned.so.1",
                 "-Wl,-rpath," + str(vendor)],
                check=True, capture_output=True,
            )

            result = subprocess.run(
                ["bash", str(ROOT / "scripts/runtime-libs.sh"), str(tree.parent)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            packages = result.stdout.strip().splitlines()
            self.assertIn("libc6", packages)
            self.assertNotIn("libunowned.so.1", packages)

    @unittest.skipUnless(shutil.which("gcc") and shutil.which("dpkg"),
                          "requires gcc to build the test fixture and dpkg to resolve ownership")
    def test_non_elf_executable_does_not_abort_the_script(self):
        # ldd exits non-zero on a script with the exec bit set (matched by find's
        # -perm -u+x); xargs then reports its own exit 123 for that miss, which
        # pipefail would otherwise treat as a hard failure of the whole script.
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            tree = td / "bin"
            tree.mkdir()

            script = tree / "not-elf.sh"
            script.write_text("#!/bin/sh\ntrue\n")
            script.chmod(0o755)

            prog_src = td / "prog.c"
            prog_src.write_text("int main(void) { return 0; }\n")
            subprocess.run(
                ["gcc", "-o", str(tree / "prog"), str(prog_src)],
                check=True, capture_output=True,
            )

            result = subprocess.run(
                ["bash", str(ROOT / "scripts/runtime-libs.sh"), str(tree)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("libc6", result.stdout.strip().splitlines())


if __name__ == "__main__":
    unittest.main()
