import contextlib
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))

import patch_isa_needed  # noqa: E402

HELLO = "int main(void) { return 0; }\n"
NOTE_OBJ = ROOT / "php" / "isa-note-x86-64-v3.S"


def have(*tools):
    return all(shutil.which(t) for t in tools)


class PatchCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.d = Path(self.tmp.name)
        (self.d / "hello.c").write_text(HELLO)

    def tearDown(self):
        self.tmp.cleanup()

    def sh(self, *args):
        return subprocess.run(args, capture_output=True, text=True, check=True, cwd=self.d)

    def check_patch(self, exe):
        data = exe.read_bytes()
        self.assertEqual(len(patch_isa_needed.isa_needed_offsets(data)), 1)
        out = self.d / "patched"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(patch_isa_needed.main([str(exe), str(out)]), 0)
        new = out.read_bytes()
        self.assertEqual(len(new), len(data))
        diff = [i for i in range(len(data)) if data[i] != new[i]]
        self.assertEqual(len(diff), 1, "only the one ISA_1_NEEDED byte may change")
        at = patch_isa_needed.isa_needed_offsets(data)[0]
        self.assertTrue(at <= diff[0] < at + 4)
        self.assertEqual(new[at], data[at] | 0x10)
        # the patched copy reads back as a valid ELF with the extra bit set
        self.assertIn("x86 ISA needed", self.sh("readelf", "-n", str(out)).stdout)
        # patching again changes nothing and is reported as an error
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(patch_isa_needed.main([str(out), str(self.d / "again")]), 1)


@unittest.skipUnless(have("gcc", "readelf") and shutil.which("ld.bfd"), "needs gcc, ld.bfd and readelf")
class TestPatchBfd(PatchCase):
    def test_gcc_mneeded_binary(self):
        exe = self.d / "hello"
        self.sh("gcc", "-march=x86-64-v3", "-mneeded", "-fuse-ld=bfd", "hello.c", "-o", str(exe))
        self.check_patch(exe)


@unittest.skipUnless(have("clang", "ld.lld", "readelf"), "needs clang, ld.lld and readelf")
class TestPatchNoteObject(PatchCase):
    def test_lld_linked_note_object(self):
        # the hand-made note object linked by lld
        self.sh("clang", "-c", str(NOTE_OBJ), "-o", "note.o")
        exe = self.d / "hello"
        self.sh("clang", "-fuse-ld=lld", "hello.c", "note.o", "-o", str(exe))
        self.check_patch(exe)


class TestRefusals(unittest.TestCase):
    def test_not_an_elf(self):
        with self.assertRaises(patch_isa_needed.ElfError):
            patch_isa_needed.isa_needed_offsets(b"#!/bin/sh\n" + b"\0" * 100)


if __name__ == "__main__":
    unittest.main()
