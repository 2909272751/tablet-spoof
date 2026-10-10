#!/usr/bin/env python3
"""
Find which dex actually DEFINES the classes Hooks.java targets.

A descriptor can appear as a raw string (method reference owner) without the
class being defined in that same dex. This walks every class_defs entry across
all dex and reports where each target class is genuinely defined, plus the
methods it defines.
"""
import os
import struct
import sys

DEXDIR = sys.argv[1]
TARGETS = [
    "com/tencent/wework/foundation/logic/Application;",
    "com/tencent/wework/foundation/impl/WeworkServiceImpl;",
]


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


class Dex:
    def __init__(self, data):
        self.d = data
        (self.string_ids_size, self.string_ids_off,
         self.type_ids_size, self.type_ids_off,
         self.proto_ids_size, self.proto_ids_off,
         self.field_ids_size, self.field_ids_off,
         self.method_ids_size, self.method_ids_off,
         self.class_defs_size, self.class_defs_off) = struct.unpack_from("<12I", data, 56)

    def string(self, i):
        off = struct.unpack_from("<I", self.d, self.string_ids_off + i * 4)[0]
        _, pos = uleb(self.d, off)
        end = self.d.index(b"\x00", pos)
        return self.d[pos:end].decode("utf-8", "replace")

    def type_desc(self, i):
        return self.string(struct.unpack_from("<I", self.d, self.type_ids_off + i * 4)[0])

    def method(self, i):
        c, p, n = struct.unpack_from("<HHI", self.d, self.method_ids_off + i * 8)
        return self.type_desc(c), self.string(n), p

    def proto_ret(self, p):
        _, ret, _ = struct.unpack_from("<III", self.d, self.proto_ids_off + p * 12)
        return self.type_desc(ret)

    def class_data_methods(self, cdo):
        if cdo == 0:
            return []
        pos = cdo
        sf, pos = uleb(self.d, pos)
        inf, pos = uleb(self.d, pos)
        dm, pos = uleb(self.d, pos)
        vm, pos = uleb(self.d, pos)
        for _ in range(sf):
            _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
        for _ in range(inf):
            _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
        out = []
        idx = 0
        for _ in range(dm):
            diff, pos = uleb(self.d, pos); idx += diff
            _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
            out.append(idx)
        idx = 0
        for _ in range(vm):
            diff, pos = uleb(self.d, pos); idx += diff
            _, pos = uleb(self.d, pos); _, pos = uleb(self.d, pos)
            out.append(idx)
        return out


def main():
    files = sorted([f for f in os.listdir(DEXDIR) if f.endswith(".dex")],
                   key=lambda n: (len(n), n))
    # Collect the type-index for our targets per dex, then match against class_defs.
    defined = {}
    for name in files:
        dx = Dex(open(os.path.join(DEXDIR, name), "rb").read())
        wanted = {}
        for ti in range(dx.type_ids_size):
            desc = dx.type_desc(ti)
            if desc in TARGETS:
                wanted[ti] = desc
        if not wanted:
            continue
        for i in range(dx.class_defs_size):
            off = dx.class_defs_off + i * 32
            ci, access, superc, ioff, srcoff, ann, cdo, sv = struct.unpack_from("<8I", dx.d, off)
            if ci in wanted:
                desc = wanted[ci]
                methods = []
                for mi in dx.class_data_methods(cdo):
                    try:
                        cdesc, mname, proto = dx.method(mi)
                        if cdesc == desc:
                            methods.append((mname, dx.proto_ret(proto)))
                    except Exception:
                        pass
                defined.setdefault(desc, []).append((name, methods))

    print("=== where each target class is DEFINED ===")
    for t in TARGETS:
        print(f"\n  {t}")
        entries = defined.get(t)
        if not entries:
            print("      NOT DEFINED IN ANY DEX (it is only referenced)")
            continue
        for name, methods in entries:
            print(f"      defined in {name}  ({len(methods)} methods)")
            interesting = [m for m in methods
                           if any(k in m[0].lower() for k in ("pad", "tablet", "device"))]
            for mname, ret in sorted(interesting):
                print(f"          {mname}() -> {ret}")
    print()


if __name__ == "__main__":
    main()
