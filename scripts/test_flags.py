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


def cflags(uarch="baseline", lang="c", compiler="gcc", machine=None):
    """Run cflags.sh as the given compiler on the given machine (uname -m is faked for arm64)."""
    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, COMPILER=compiler)
        if machine:
            fake = Path(tmp) / "uname"
            fake.write_text(f"#!/bin/sh\necho {machine}\n")
            fake.chmod(0o755)
            env["PATH"] = f"{tmp}:{os.environ['PATH']}"
        return run("php/cflags.sh", uarch, lang, env=env).split()


MACHINES = ("x86_64", "aarch64")
COMPILERS = ("gcc", "clang")
# Wolfi's default hardening set that the Dockerfile switches off and cflags.sh restores.
RESTORED = ("-ftrivial-auto-var-init=zero", "-fno-delete-null-pointer-checks",
            "-fno-strict-overflow", "-fno-strict-aliasing")


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

    def test_no_isa_note_flag(self):
        # The v3 startup refusal is a linked-in constructor (php/isa-gate-x86-64-v3.c),
        # not a GNU property note, so no flag asks the compiler for one.
        for compiler in COMPILERS:
            env = dict(os.environ, COMPILER=compiler)
            for uarch in ("baseline", "v3"):
                self.assertNotIn("-mneeded", run("php/cflags.sh", uarch, env=env).split())

    def test_arch_specific_cfi_flag(self):
        flags = run("php/cflags.sh", "baseline")
        self.assertTrue("-fcf-protection=full" in flags or "-mbranch-protection=standard" in flags)

    def test_cfi_flag_per_arch(self):
        for compiler in COMPILERS:
            for uarch in ("baseline", "v3"):
                amd64 = cflags(uarch, "c", compiler, "x86_64")
                arm64 = cflags(uarch, "c", compiler, "aarch64")
                self.assertIn("-fcf-protection=full", amd64)
                self.assertNotIn("-mbranch-protection=standard", amd64)
                self.assertIn("-mbranch-protection=standard", arm64)
                self.assertNotIn("-fcf-protection=full", arm64)

    def test_restored_default_hardening_on_every_combination(self):
        for machine in MACHINES:
            for compiler in COMPILERS:
                for uarch in ("baseline", "v3"):
                    for lang in ("c", "cxx"):
                        flags = cflags(uarch, lang, compiler, machine)
                        label = (machine, compiler, uarch, lang)
                        for expected in RESTORED + ("-O2", "-fstack-protector-strong",
                                                    "-fstack-clash-protection", "-D_FORTIFY_SOURCE=3"):
                            self.assertIn(expected, flags, label)

    def test_zero_init_padding_bits_is_gcc_only(self):
        # clang (19 and later) has no such option and errors on it.
        for machine in MACHINES:
            for lang in ("c", "cxx"):
                self.assertIn("-fzero-init-padding-bits=all", cflags("baseline", lang, "gcc", machine))
                self.assertNotIn("-fzero-init-padding-bits=all", cflags("baseline", lang, "clang", machine))

    def test_language_specific_flags(self):
        for compiler in COMPILERS:
            c = cflags("baseline", "c", compiler)
            cxx = cflags("baseline", "cxx", compiler)
            self.assertIn("-std=gnu17", c)
            self.assertNotIn("-D_GLIBCXX_ASSERTIONS", c)
            # callers append their own -std=c++NN; gnu17 is invalid for C++
            self.assertNotIn("-std=gnu17", cxx)
            self.assertIn("-D_GLIBCXX_ASSERTIONS", cxx)

    def test_c_and_cxx_differ_only_in_language_flags(self):
        for compiler in COMPILERS:
            c = set(cflags("v3", "c", compiler)) - {"-std=gnu17"}
            cxx = set(cflags("v3", "cxx", compiler)) - {"-D_GLIBCXX_ASSERTIONS"}
            self.assertEqual(c, cxx)

    def test_language_defaults_to_c(self):
        self.assertEqual(run("php/cflags.sh", "baseline"), run("php/cflags.sh", "baseline", "c"))

    def test_unknown_language_and_compiler_fail(self):
        with self.assertRaises(subprocess.CalledProcessError):
            run("php/cflags.sh", "baseline", "fortran")
        with self.assertRaises(subprocess.CalledProcessError):
            run("php/cflags.sh", "baseline", "c", env=dict(os.environ, COMPILER="icc"))

    def test_mtune_is_explicit_and_identical_across_compilers(self):
        expected = {("x86_64", "baseline"): "-mtune=generic", ("x86_64", "v3"): "-mtune=generic",
                    ("aarch64", "baseline"): "-mtune=generic", ("aarch64", "v3"): "-mtune=neoverse-v2"}
        for (machine, uarch), mtune in expected.items():
            per_compiler = [[f for f in cflags(uarch, "c", c, machine) if f.startswith("-mtune=")]
                            for c in COMPILERS]
            self.assertEqual(per_compiler, [[mtune], [mtune]], (machine, uarch))

    def test_arm64_march_per_level(self):
        for compiler in COMPILERS:
            self.assertIn("-march=armv8-a", cflags("baseline", "c", compiler, "aarch64"))
            self.assertIn("-march=armv9-a", cflags("v3", "c", compiler, "aarch64"))

    def test_fortify_not_redefined_after_the_final_level(self):
        # -U must come before the only -D, for every combination.
        for machine in MACHINES:
            flags = cflags("v3", "cxx", "clang", machine)
            self.assertEqual([f for f in flags if f.startswith("-D_FORTIFY_SOURCE")], ["-D_FORTIFY_SOURCE=3"])


class TestLdflags(unittest.TestCase):
    def test_full_relro_and_noexecstack(self):
        flags = run("php/ldflags.sh")
        self.assertIn("-Wl,-z,relro", flags)
        self.assertIn("-Wl,-z,now", flags)
        self.assertIn("-Wl,-z,noexecstack", flags)
        self.assertIn("-Wl,--as-needed", flags)

    def _flags_with_linker(self, banner):
        # A stand-in `ld` first on PATH decides what ldflags.sh sees as the linker.
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "ld"
            fake.write_text(f"#!/bin/sh\necho '{banner}'\n")
            fake.chmod(0o755)
            env = dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}")
            return run("php/ldflags.sh", env=env)

    def test_packed_relocs_for_gnu_ld_and_lld(self):
        for banner in ("GNU ld (GNU Binutils) 2.47", "LLD 19.1.7 (compatible with GNU linkers)"):
            self.assertIn("-Wl,-z,pack-relative-relocs", self._flags_with_linker(banner).split(), banner)

    def test_no_packed_relocs_for_gold(self):
        # gold fails the link on `-z pack-relative-relocs` instead of ignoring it.
        self.assertNotIn("pack-relative-relocs", self._flags_with_linker("GNU gold (GNU Binutils 2.47) 1.16"))

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
