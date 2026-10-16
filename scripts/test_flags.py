import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def run(script, *args, env=None):
    out = subprocess.run(["bash", str(ROOT / script), *args],
                         capture_output=True, text=True, check=True, env=env)
    return out.stdout.strip()


class TestCflags(unittest.TestCase):
    def test_hardening_flags_always_present(self):
        flags = run("php/cflags.sh", "baseline")
        for expected in ("-fstack-protector-strong", "-fstack-clash-protection",
                         "-D_FORTIFY_SOURCE=3", "-fPIC"):
            self.assertIn(expected, flags)

    def test_fortify_is_undefined_first(self):
        # the build environment may already define it; redefining without -U warns and may not apply
        flags = run("php/cflags.sh", "baseline")
        self.assertIn("-U_FORTIFY_SOURCE", flags)
        self.assertLess(flags.index("-U_FORTIFY_SOURCE"), flags.index("-D_FORTIFY_SOURCE=3"))

    def test_baseline_and_v3_differ(self):
        self.assertNotEqual(run("php/cflags.sh", "baseline"), run("php/cflags.sh", "v3"))

    def test_baseline_march(self):
        flags = run("php/cflags.sh", "baseline")
        self.assertTrue("-march=x86-64-v2 -mtune=generic" in flags or "-march=armv8-a" in flags, flags)
        self.assertNotIn("-mtune=sapphirerapids", flags)

    def test_v3_sets_a_march(self):
        flags = run("php/cflags.sh", "v3")
        self.assertTrue("-march=x86-64-v3" in flags or "-march=armv9-a" in flags)

    def test_mneeded_only_on_gcc_amd64_v3(self):
        # -mneeded makes gcc's v3 objects carry GNU_PROPERTY_X86_ISA_1_NEEDED so
        # glibc refuses the binary on a CPU without x86-64-v3. clang rejects the
        # flag; baseline and arm64 must not carry it.
        gcc = dict(os.environ, COMPILER="gcc")
        clang = dict(os.environ, COMPILER="clang")
        unset = {k: v for k, v in os.environ.items() if k != "COMPILER"}
        v3_gcc = run("php/cflags.sh", "v3", env=gcc).split()
        if "-march=x86-64-v3" in v3_gcc:
            self.assertIn("-mneeded", v3_gcc)
        else:
            self.assertNotIn("-mneeded", v3_gcc)
        self.assertNotIn("-mneeded", run("php/cflags.sh", "baseline", env=gcc).split())
        self.assertNotIn("-mneeded", run("php/cflags.sh", "v3", env=clang).split())
        self.assertNotIn("-mneeded", run("php/cflags.sh", "v3", env=unset).split())

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
        # A global LD_LIBRARY_PATH would let a vendored libcurl shadow the system's
        # for every process in the image; rpath binds the search path to the binary.
        flags = run("php/ldflags.sh", "/opt/php-deps")
        self.assertIn("-Wl,-rpath,/opt/php-deps/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/php-deps/lib", flags)

    def test_multiple_prefixes_each_emit_rpath(self):
        # /opt/imagemagick (all PHP versions) and /opt/php-deps (legacy only)
        # both need to be on the search path of the same binary.
        flags = run("php/ldflags.sh", "/opt/imagemagick", "/opt/php-deps")
        self.assertIn("-Wl,-rpath,/opt/imagemagick/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/imagemagick/lib", flags)
        self.assertIn("-Wl,-rpath,/opt/php-deps/lib", flags)
        self.assertIn("-Wl,-rpath-link,/opt/php-deps/lib", flags)


class TestRuntimeLibs(unittest.TestCase):
    @unittest.skipUnless(shutil.which("gcc") and shutil.which("apk"),
                          "requires gcc to build the test fixture and apk to resolve ownership")
    def test_mixed_owned_and_unowned_libraries(self):
        # One dependency resolves to a Wolfi package (glibc-<major.minor>); the other, via
        # rpath, to a scratch-built .so owned by no package (standing in for
        # a vendored library). The unowned one must be skipped, not abort the script.
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
            self.assertTrue([p for p in packages if re.fullmatch(r"glibc(-[0-9.]+)?", p)], packages)
            self.assertFalse([p for p in packages if "unowned" in p], packages)
            self.assertIn("libunowned.so.1", result.stderr)

    @unittest.skipUnless(shutil.which("gcc"), "requires gcc to build the test fixture")
    def test_unresolvable_library_is_fatal(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            vendor = td / "vendor"
            vendor.mkdir()
            tree = td / "tree"
            tree.mkdir()
            (td / "lib.c").write_text("int gone_fn(void) { return 42; }\n")
            subprocess.run(
                ["gcc", "-shared", "-fPIC", "-Wl,-soname,libgone.so.1",
                 "-o", str(vendor / "libgone.so.1"), str(td / "lib.c")],
                check=True, capture_output=True,
            )
            (td / "prog.c").write_text(
                "extern int gone_fn(void);\n"
                "int main(void) { return gone_fn() == 42 ? 0 : 1; }\n"
            )
            subprocess.run(
                ["gcc", "-o", str(tree / "prog"), str(td / "prog.c"),
                 "-L" + str(vendor), "-l:libgone.so.1"],
                check=True, capture_output=True,
            )
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/runtime-libs.sh"), str(tree)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 1, result.stdout)
            self.assertIn("libgone.so.1", result.stderr)

    @unittest.skipUnless(shutil.which("gcc") and shutil.which("apk"),
                          "requires gcc to build the test fixture and apk to resolve ownership")
    def test_names_carry_no_version_suffix(self):
        with tempfile.TemporaryDirectory() as tmp:
            td = Path(tmp)
            tree = td / "bin"
            tree.mkdir()
            prog_src = td / "prog.c"
            prog_src.write_text("int main(void) { return 0; }\n")
            subprocess.run(["gcc", "-o", str(tree / "prog"), str(prog_src)],
                           check=True, capture_output=True)

            result = subprocess.run(
                ["bash", str(ROOT / "scripts/runtime-libs.sh"), str(tree)],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(result.stdout.strip(), "runtime-libs.sh printed no packages")
            for name in result.stdout.split():
                self.assertNotRegex(name, r"-[0-9][^-]*-r[0-9]+$")

    @unittest.skipUnless(shutil.which("gcc") and shutil.which("apk"),
                          "requires gcc to build the test fixture and apk to resolve ownership")
    def test_non_elf_executable_does_not_abort_the_script(self):
        # The loader exits non-zero on an exec-bit script; xargs would report
        # exit 123 and pipefail would abort the script.
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
            self.assertTrue([p for p in result.stdout.split() if re.fullmatch(r"glibc(-[0-9.]+)?", p)], result.stdout)


if __name__ == "__main__":
    unittest.main()
