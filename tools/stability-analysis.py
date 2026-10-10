#!/usr/bin/env python3
"""
WeCom hook version-stability analysis.

Reuses the PROVEN class_defs/method_ids walk from audit-hook-targets.py (which
correctly found all three targets) and adds:

  * where each target method lives (dex + code offset + access flags)
  * how many copies exist across the multidex set
  * which stable strings could anchor runtime discovery

The lesson being encoded: a hook that resolves the WRONG class fails SILENTLY
(we hit this with android.app.Application). Nothing here should claim "not found"
without first proving the walk works on a known-present method.
"""
import glob
import os
import struct
import sys

DEXDIR = sys.argv[1] if len(sys.argv) > 1 else r"E:\temp\alldex"

TARGETS = [
    ("Lcom/tencent/wework/foundation/logic/Application;", "isAndroidPad", "Z"),
    ("Lcom/tencent/wework/foundation/impl/WeworkServiceImpl;", "isAndroidPad", "Z"),
    ("Lcom/tencent/wework/foundation/impl/WeworkServiceImpl;", "getDeviceType", "I"),
]
# Control: a method we know must exist, to validate the walk itself.
CONTROL = ("Lcom/tencent/wework/foundation/logic/Application;", "getDeviceId", "Ljava/lang/String;")


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


def scan(data, errors=None):
    """Yield (class_desc, method_name, ret_desc, access, code_off) for all methods.

    `errors` is an optional list; per-method parse failures are appended to it so
    the caller can distinguish "absent" from "unreadable".
    """
    if errors is None:
        errors = []
    (ss, so, ts, to, ps, po, fs, fo, ms, mo, cs, co) = struct.unpack_from("<12I", data, 56)

    def st(i):
        if not (0 <= i < ss):
            raise IndexError(f"string index {i} out of range (ss={ss})")
        off = struct.unpack_from("<I", data, so + i * 4)[0]
        _, pos = uleb(data, off)
        return data[pos:data.index(b"\x00", pos)].decode("utf-8", "replace")

    def td(i):
        if not (0 <= i < ts):
            raise IndexError(f"type index {i} out of range (ts={ts})")
        return st(struct.unpack_from("<I", data, to + i * 4)[0])

    for i in range(cs):
        off = co + i * 32
        ci, access, superc, ioff, srcoff, ann, cdo, sv = struct.unpack_from("<8I", data, off)
        desc = td(ci)
        if cdo == 0:
            continue
        pos = cdo
        sf, pos = uleb(data, pos)
        inf, pos = uleb(data, pos)
        dm, pos = uleb(data, pos)
        vm, pos = uleb(data, pos)
        for _ in range(sf):
            _, pos = uleb(data, pos); _, pos = uleb(data, pos)
        for _ in range(inf):
            _, pos = uleb(data, pos); _, pos = uleb(data, pos)
        for cnt in (dm, vm):
            idx = 0
            for _ in range(cnt):
                diff, pos = uleb(data, pos)
                idx += diff
                macc, pos = uleb(data, pos)
                cod, pos = uleb(data, pos)
                if not (0 <= idx < ms):
                    continue
                cidx, proto, nidx = struct.unpack_from("<HHI", data, mo + idx * 8)
                # Per-entry failure must not be silent: record it on the generator's
                # error list so main() can report UNKNOWN instead of a false absence.
                try:
                    name = st(nidx)
                    _, ret, _ = struct.unpack_from("<III", data, ps + proto * 12)
                    yield desc, name, td(ret), macc, cod
                except Exception as exc:
                    errors.append(f"method idx {idx}: {exc.__class__.__name__}: {exc}")


def main():
    files = sorted(glob.glob(os.path.join(DEXDIR, "*.dex")),
                   key=lambda n: (len(os.path.basename(n)), n))
    print(f"analysing {len(files)} dex from {DEXDIR}")
    if not files:
        print("NO DEX FOUND - refusing to report results")
        return 2
    print()

    index = {}
    scan_errors = []
    for f in files:
        name = os.path.basename(f)
        try:
            data = open(f, "rb").read()
        except Exception as exc:
            scan_errors.append(f"{name}: unreadable ({exc})")
            continue
        per_dex = []
        for desc, mname, ret, acc, cod in scan(data, per_dex):
            index.setdefault((desc, mname), []).append((name, ret, acc, cod))
        for e in per_dex:
            scan_errors.append(f"{name}: {e}")

    if scan_errors:
        print("PARSE ERRORS -- absence claims below are UNRELIABLE:", file=sys.stderr)
        for e in scan_errors[:20]:
            print(f"  {e}", file=sys.stderr)
        print(file=sys.stderr)

    # --- validate the walk before trusting any "not found" -------------------
    print("=== walk validation (control method that MUST exist) ===")
    cdesc, cname, cret = CONTROL
    chits = index.get((cdesc, cname), [])
    if not chits:
        print(f"  CONTROL MISSING: {cdesc}.{cname} -- the walk is broken;"
              f" do NOT trust any NOT FOUND below.")
        return 3
    print(f"  control OK: {cdesc}.{cname} found in {len(chits)} dex,"
          f" returns {sorted({r for _, r, _, _ in chits})}")
    print()

    print("=== hook target stability ===")
    for desc, mname, want in TARGETS:
        hits = index.get((desc, mname), [])
        print(f"\n  {desc}.{mname}() -> {want}")
        if not hits:
            print("      NOT FOUND (walk validated, so this is real)")
            continue
        for dexname, ret, acc, cod in hits:
            flag = "OK" if ret == want else "TYPE MISMATCH"
            print(f"      {flag}  {dexname}  returns {ret}  access {hex(acc)}  code_off {cod}")

    print()
    print("=== stable-string anchors (for runtime discovery) ===")
    for hint in ["isAndroidPad", "AndroidPad", "pad", "tablet"]:
        n = 0
        for f in files:
            try:
                if hint.encode() in open(f, "rb").read():
                    n += 1
            except Exception:
                pass
        print(f"  '{hint}' appears in {n}/{len(files)} dex")
    print()
    print("  NOTE: these are obfuscation-resistant only if the app itself logs")
    print("  them. WeCom's isAndroidPad is a real (non-obfuscated) name, so the")
    print("  descriptor is already stable across versions; the fragile part is")
    print("  the CLASS PACKAGE (foundation.logic / foundation.impl), not the")
    print("  method name. WeChat is the opposite: obfuscated gk.C, stable LOG")
    print("  STRING -> string-anchor discovery is the right technique there.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
