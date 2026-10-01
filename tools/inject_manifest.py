"""Replace the RT_MANIFEST resource of a PE file, stdlib only.

Walks the three level resource tree (type -> name -> language) using
offsets that are always relative to the resource section base.
"""
import struct
import sys

RT_MANIFEST = 24


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def rva_to_off(pe, rva):
    pe_off = u32(pe, 0x3C)
    n_sec = u16(pe, pe_off + 6)
    opt_size = u16(pe, pe_off + 20)
    sec = pe_off + 24 + opt_size
    for i in range(n_sec):
        o = sec + i * 40
        vsize = u32(pe, o + 8)
        vaddr = u32(pe, o + 12)
        rsize = u32(pe, o + 16)
        praw = u32(pe, o + 20)
        if vaddr <= rva < vaddr + max(vsize, rsize):
            return rva - vaddr + praw
    raise ValueError("RVA 0x%X outside sections" % rva)


def dir_entries(d, off):
    """Yield (name_or_id, data_or_subdir_offset) for a directory at `off`."""
    n_named = u16(d, off + 12)
    n_id = u16(d, off + 14)
    p = off + 16
    for _ in range(n_named + n_id):
        name = u32(d, p)
        target = u32(d, p + 4)
        yield name, target
        p += 8


def res_name(d, base, name_field):
    if not (name_field & 0x80000000):
        return name_field
    off = base + (name_field & 0x7FFFFFFF)
    ln = u16(d, off)
    return d[off + 2: off + 2 + ln * 2].decode("utf-16-le")


def data_entry(pe, base, off):
    """Return (file_offset, size) for a leaf data entry."""
    rva = u32(pe, base + off)
    size = u32(pe, base + off + 4)
    return rva_to_off(pe, rva), size


def locate(pe):
    pe_off = u32(pe, 0x3C)
    magic = u16(pe, pe_off + 24)
    dd_off = pe_off + 24 + (112 if magic == 0x20B else 96)
    rsrc_rva = u32(pe, dd_off + 2 * 8)
    if not rsrc_rva:
        return None
    base = rva_to_off(pe, rsrc_rva)

    def target(abs_off):
        """Resolve a directory entry target, which is a section-relative
        offset with the high bit used as the subdirectory flag."""
        is_dir = bool(abs_off & 0x80000000)
        rel = abs_off & 0x7FFFFFFF
        return base + rel, is_dir

    for name, t1 in dir_entries(pe, base):
        tid = res_name(pe, base, name)
        if tid != RT_MANIFEST and tid != str(RT_MANIFEST):
            continue
        lvl2, _ = target(t1)
        for _n2, t2 in dir_entries(pe, lvl2):
            lvl3, _ = target(t2)
            for _n3, t3 in dir_entries(pe, lvl3):
                leaf, _ = target(t3)
                return data_entry(pe, base, leaf - base)
    return None


def main():
    exe, mf = sys.argv[1], sys.argv[2]
    with open(mf, "rb") as fh:
        new = fh.read()
    with open(exe, "rb") as fh:
        pe = bytearray(fh.read())

    hit = locate(pe)
    if not hit:
        print("NO_MANIFEST")
        return 2
    off, size = hit
    print("manifest slot: offset=0x%X size=%d" % (off, size))
    if len(new) > size:
        print("TOO_BIG need=%d have=%d" % (len(new), size))
        return 3
    pe[off: off + size] = new + b" " * (size - len(new))
    with open(exe, "wb") as fh:
        fh.write(pe)
    print("PATCHED ok (padded %d)" % (size - len(new)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
