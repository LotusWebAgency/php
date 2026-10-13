#!/usr/bin/env python3
"""Copy an x86-64 ELF executable with extra bits OR-ed into its
GNU_PROPERTY_X86_ISA_1_NEEDED word.

tests/test-uarch.sh uses it to prove that the v3 ISA note is enforced by the
image's glibc: a copy whose note also demands an ISA bit no CPU has must be
refused by ld.so ("CPU ISA level is lower than required", exit 127), while the
unpatched binary runs. The runtime images have no python, so this runs on the
host.

The note is located the way ld.so does: walk the PT_NOTE segments, step through
the notes (name padded to 4, descriptor to the segment's alignment), take
NT_GNU_PROPERTY_TYPE_0 owned by "GNU", and walk its properties for pr_type
0xc0008002. No byte search.

    patch_isa_needed.py <in> <out> [--or 0x10]
"""
import argparse
import os
import struct
import sys

PT_NOTE = 4
NT_GNU_PROPERTY_TYPE_0 = 5
GNU_PROPERTY_X86_ISA_1_NEEDED = 0xC0008002


class ElfError(Exception):
    pass


def _align(n, a):
    return (n + a - 1) & ~(a - 1)


def isa_needed_offsets(data):
    """File offsets of every 32-bit ISA_1_NEEDED data word in an ELF64 LE image."""
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ElfError("not a little-endian ELF64 file")
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    found = []
    for i in range(e_phnum):
        ph = e_phoff + i * e_phentsize
        p_type, _flags, p_offset, _va, _pa, p_filesz, _memsz, p_align = \
            struct.unpack_from("<IIQQQQQQ", data, ph)
        if p_type != PT_NOTE:
            continue
        align = p_align if p_align in (4, 8) else 4
        pos, end = p_offset, p_offset + p_filesz
        while pos + 12 <= end:
            namesz, descsz, n_type = struct.unpack_from("<III", data, pos)
            name_at = pos + 12
            desc_at = name_at + _align(namesz, 4)
            next_at = desc_at + _align(descsz, align)
            if next_at > end:
                raise ElfError("note overruns its PT_NOTE segment")
            if n_type == NT_GNU_PROPERTY_TYPE_0 and data[name_at:name_at + namesz] == b"GNU\0":
                p, desc_end = desc_at, desc_at + descsz
                while p + 8 <= desc_end:
                    pr_type, pr_datasz = struct.unpack_from("<II", data, p)
                    if pr_type == GNU_PROPERTY_X86_ISA_1_NEEDED:
                        if pr_datasz != 4:
                            raise ElfError("ISA_1_NEEDED property is not 4 bytes")
                        found.append(p + 8)
                    p += 8 + _align(pr_datasz, 8)
            pos = next_at
    return found


def patch(data, or_bits):
    offsets = isa_needed_offsets(data)
    if len(offsets) != 1:
        raise ElfError("expected exactly one GNU_PROPERTY_X86_ISA_1_NEEDED, found %d" % len(offsets))
    at = offsets[0]
    old, = struct.unpack_from("<I", data, at)
    new = old | or_bits
    if new == old:
        raise ElfError("ISA_1_NEEDED already has bits 0x%x (0x%x): the patch changes nothing" % (or_bits, old))
    out = bytearray(data)
    struct.pack_into("<I", out, at, new)
    return bytes(out), old, new


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--or", dest="or_bits", type=lambda s: int(s, 0), default=0x10,
                    help="bits to OR into ISA_1_NEEDED (default 0x10, which no CPU supports)")
    args = ap.parse_args(argv)
    with open(args.src, "rb") as f:
        data = f.read()
    try:
        out, old, new = patch(data, args.or_bits)
    except ElfError as e:
        print("patch_isa_needed: %s: %s" % (args.src, e), file=sys.stderr)
        return 1
    with open(args.dst, "wb") as f:
        f.write(out)
    os.chmod(args.dst, os.stat(args.src).st_mode & 0o777)
    print("ISA_1_NEEDED 0x%x -> 0x%x" % (old, new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
