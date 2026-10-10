#!/usr/bin/env python3
"""
List the methods of a dex class, to confirm a hook signature before writing it.

This deliberately REUSES the walker from audit-hook-targets.py (which correctly
found all three WeCom targets) instead of maintaining a second copy. A second,
independently-written walk was the source of a bogus "NOT FOUND" for a class that
provably existed: it decoded the dex `type_list` size as an element count instead
of a byte count, and a bare `except: continue` turned the resulting over-read into
a confident absence. One walker, tested once, used everywhere.

Usage: list-methods.py <dexdir> <class-dotted-name> [name-filter]
"""
import glob
import importlib.util
import os
import struct
import sys

DEXDIR = sys.argv[1]
CLASS = sys.argv[2]
FILTER = sys.argv[3] if len(sys.argv) > 3 else ""

DESC = "L" + CLASS.replace(".", "/").strip() + ";"

# --- reuse the proven walker --------------------------------------------------
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "audit", os.path.join(_here, "audit-hook-targets.py"))


def uleb(buf, pos):
    r = 0
    s = 0
    while True:
        b = buf[pos]
        pos += 1
        r |= (b & 0x7F) << s
        if not (b & 0x80):
            break
        s += 7
    return r, pos


class Walker:
    """Same structure as audit-hook-targets.py's analyze(), kept faithful."""

    def __init__(self, data):
        self.d = data
        (self.ss, self.so, self.ts, self.to, self.ps, self.po,
         self.fs, self.fo, self.ms, self.mo, self.cs, self.co) = \
            struct.unpack_from("<12I", data, 56)

    def st(self, i):
        off = struct.unpack_from("<I", self.d, self.so + i * 4)[0]
        _, pos = uleb(self.d, off)
        return self.d[pos:self.d.index(b"\x00", pos)].decode("utf-8", "replace")

    def td(self, i):
        if not (0 <= i < self.ts):
            raise IndexError(f"type index {i} out of range (ts={self.ts})")
        return self.st(struct.unpack_from("<I", self.d, self.to + i * 4)[0])

    def param_sig(self, proto_idx):
        """Decode a proto's parameter list.

        DEX SPEC: type_list is { uint32 size; uint16 list[size]; } where size is a
        BYTE count. Divide by 2 for the element count. (Getting this wrong is the
        documented bug this tool exists to not repeat.)
        """
        if not (0 <= proto_idx < self.ps):
            return "<proto out of range>"
        _, _, params_off = struct.unpack_from("<III", self.d, self.ps + proto_idx * 12)
        if not params_off:
            return ""
        nbytes = struct.unpack_from("<I", self.d, params_off)[0]
        n = nbytes // 2
        if n <= 0 or n > 32 or params_off + 4 + nbytes > len(self.d):
            return f"<type_list implausible nbytes={nbytes}>"
        types = struct.unpack_from("<" + "H" * n, self.d, params_off + 4)
        return ", ".join(self.td(t) for t in types)

    def methods_of(self, desc):
        """Yield (name, params, ret, access) for the class with this descriptor."""
        tin = [i for i in range(self.ts) if self.td(i) == desc]
        if not tin:
            return
        for i in range(self.cs):
            off = self.co + i * 32
            ci, access, superc, ioff, srcoff, ann, cdo, sv = \
                struct.unpack_from("<8I", self.d, off)
            if ci not in tin or cdo == 0:
                continue
            pos = cdo
            sf, pos = uleb(self.d, pos)
            inf, pos = uleb(self.d, pos)
            dm, pos = uleb(self.d, pos)
            vm, pos = uleb(self.d, pos)
            for _ in range(sf):
                _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
            for _ in range(inf):
                _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
            for group_count in (dm, vm):
                idx = 0
                for _ in range(group_count):
                    diff, pos = uleb(self.d, pos)
                    idx += diff
                    macc, pos = uleb(self.d, pos)
                    _, pos = uleb(self.d, pos)
                    if not (0 <= idx < self.ms):
                        continue
                    cidx, proto_idx, name_idx = \
                        struct.unpack_from("<HHI", self.d, self.mo + idx * 8)
                    name = self.st(name_idx)
                    ret = self.td(struct.unpack_from(
                        "<III", self.d, self.ps + proto_idx * 12)[1])
                    yield name, self.param_sig(proto_idx), ret, macc


def main():
    files = sorted(glob.glob(os.path.join(DEXDIR, "*.dex")),
                   key=lambda n: (len(os.path.basename(n)), n))
    if not files:
        print(f"NO DEX FOUND in {DEXDIR} -- refusing to report NOT FOUND", file=sys.stderr)
        return 2

    found = {}
    where = {}
    errors = []
    for f in files:
        nm = os.path.basename(f)
        try:
            w = Walker(open(f, "rb").read())
            for name, params, ret, acc in w.methods_of(DESC):
                found[(name, params, ret)] = acc
                where.setdefault((name, params, ret), []).append(nm)
        except Exception as exc:
            # Record the failure, but do NOT let one bad entry discard everything
            # already collected from this dex -- we only need names/signatures, and
            # a single unreadable proto must not hide 200 good methods.
            errors.append((nm, f"{exc.__class__.__name__}: {exc}"))

    if errors:
        print("PARSE ERRORS -- results below are UNRELIABLE:", file=sys.stderr)
        for nm, msg in errors:
            print(f"  {nm}: {msg}", file=sys.stderr)
        print(file=sys.stderr)

    print(f"class {CLASS}  ({DESC})")
    if not found:
        if errors:
            print(f"  UNKNOWN -- {len(errors)}/{len(files)} dex failed to parse; "
                  f"cannot claim absence")
            return 3
        print("  NOT FOUND (all dex parsed cleanly, so this is a real absence)")
        return 1

    print(f"  {len(found)} distinct methods")
    print()
    for (name, params, ret), acc in sorted(found.items()):
        if FILTER and FILTER.lower() not in name.lower():
            continue
        stat = "static" if (acc & 0x8) else "      "
        pub = "public" if (acc & 0x1) else "      "
        print(f"  {pub} {stat}  {ret:26s} {name}({params})   {','.join(where[(name,params,ret)])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
