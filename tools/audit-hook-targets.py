#!/usr/bin/env python3
"""
Definitive audit: confirm the exact method signatures Hooks.java targets.

Per dex:
  1. find the type index for each target descriptor
  2. find the class_defs entry referencing it
  3. walk class_data -> direct+virtual methods -> method_ids -> name + proto
  4. report the return type so we can confirm Z (boolean) / I (int)
"""
import glob
import os
import struct
import sys

DEXDIR = sys.argv[1] if len(sys.argv) > 1 else r"E:\temp\alldex"

# DEX type descriptors carry the leading 'L' and trailing ';', e.g.
#   Lcom/tencent/wework/foundation/logic/Application;
# These keys must include both, or the lookup silently matches nothing.
TARGETS = {
    "Lcom/tencent/wework/foundation/logic/Application;": ["isAndroidPad"],
    "Lcom/tencent/wework/foundation/impl/WeworkServiceImpl;": ["isAndroidPad", "getDeviceType"],
}


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


def analyze(d):
    (ss, so, ts, to, ps, po, fs, fo, ms, mo, cs, co) = struct.unpack_from("<12I", d, 56)

    def st(i):
        off = struct.unpack_from("<I", d, so + i * 4)[0]
        _, pos = uleb(d, off)
        return d[pos:d.index(b"\x00", pos)].decode("utf-8", "replace")

    def td(i):
        return st(struct.unpack_from("<I", d, to + i * 4)[0])

    # Find type indices for our targets.
    tindex = {}
    for i in range(ts):
        desc = td(i)
        if desc in TARGETS:
            tindex[desc] = i

    if not tindex:
        return None

    results = {}
    # Map type index -> class_defs entry.
    for i in range(cs):
        off = co + i * 32
        ci, access, superc, ioff, srcoff, ann, cdo, sv = struct.unpack_from("<8I", d, off)
        desc = None
        for name, ti in tindex.items():
            if ci == ti:
                desc = name
                break
        if desc is None:
            continue
        if cdo == 0:
            results[desc] = ("no class_data", [])
            continue

        pos = cdo
        sf, pos = uleb(d, pos)
        inf, pos = uleb(d, pos)
        dm, pos = uleb(d, pos)
        vm, pos = uleb(d, pos)
        for _ in range(sf):
            _, pos = uleb(d, pos); _, pos = uleb(d, pos)
        for _ in range(inf):
            _, pos = uleb(d, pos); _, pos = uleb(d, pos)

        methods = []
        for group_count in (dm, vm):
            idx = 0
            for _ in range(group_count):
                diff, pos = uleb(d, pos); idx += diff
                _, pos = uleb(d, pos)
                _, pos = uleb(d, pos)
                # method_ids[idx]
                cidx, proto_idx, name_idx = struct.unpack_from("<HHI", d, mo + idx * 8)
                mname = st(name_idx)
                _, ret_idx, _ = struct.unpack_from("<III", d, po + proto_idx * 12)
                methods.append((mname, td(ret_idx)))
        results[desc] = ("ok", methods)
    return results


def main():
    files = sorted(glob.glob(os.path.join(DEXDIR, "*.dex")),
                   key=lambda n: (len(os.path.basename(n)), n))
    print(f"scanning {len(files)} dex in {DEXDIR}")
    print()

    overall = {}
    for f in files:
        name = os.path.basename(f)
        try:
            res = analyze(open(f, "rb").read())
        except Exception as exc:
            print(f"  {name}: parse error {exc}")
            continue
        if not res:
            continue
        for desc, (status, methods) in res.items():
            overall.setdefault(desc, []).append((name, status, methods))

    print("=== DEFINITIVE AUDIT of Hooks.java targets ===")
    ok = True
    for desc, wanted in TARGETS.items():
        entries = overall.get(desc)
        print(f"\n  {desc}")
        if not entries:
            print("      NOT FOUND ANYWHERE")
            ok = False
            continue
        for name, status, methods in entries:
            print(f"      defined in {name} ({status}), {len(methods)} methods")
        # gather all methods across copies
        allm = {}
        for name, status, methods in entries:
            for mname, ret in methods:
                allm.setdefault(mname, set()).add(ret)
        for m in wanted:
            rets = allm.get(m)
            if not rets:
                print(f"      MISSING method {m}()")
                ok = False
            else:
                print(f"      method {m}() -> returns {sorted(rets)}")
        print("      other pad/tablet/device-ish methods on this class:")
        for mname in sorted(allm):
            if any(k in mname.lower() for k in ("pad", "tablet", "device")):
                print(f"          {mname}() -> {sorted(allm[mname])}")

    print()
    print("AUDIT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
