#!/usr/bin/env python3
"""Targeted vectors for FMIN/FMAX/FCLASS, which TestFloat does not cover.

Writes f32_min, f32_max, f32_class, f64_min, f64_max and f64_class vectors
in testfloat_gen's line format (operands, result, flags) into OUTDIR. The
expected results follow the RISC-V rules (IEEE 754-2019 minimumNumber /
maximumNumber with -0 < +0; NV only for a signaling NaN input; the canonical
NaN when both inputs are NaN). Every case of riscv-tests' rv64uf/rv64ud
fmin.S and fclass.S is checked against these rules and then added too.

usage: special.py RISCV_TESTS_DIR OUTDIR
"""

import os
import re
import struct
import sys

NV = 0x10


class Fmt:
    def __init__(self, name, bits, ebits, pack):
        self.name, self.bits, self.ebits, self.pack = name, bits, ebits, pack
        self.mbits = bits - 1 - ebits
        self.emax = (1 << ebits) - 1
        self.sign = 1 << (bits - 1)
        self.qbit = 1 << (self.mbits - 1)
        self.qnan = (self.emax << self.mbits) | self.qbit
        self.digits = bits // 4

    def parts(self, v):
        return v >> (self.bits - 1), (v >> self.mbits) & self.emax, v & ((1 << self.mbits) - 1)

    def is_nan(self, v):
        _, e, m = self.parts(v)
        return e == self.emax and m != 0

    def is_snan(self, v):
        return self.is_nan(v) and not (v & self.qbit)

    def value(self, v):
        return struct.unpack(">" + self.pack, v.to_bytes(self.bits // 8, "big"))[0]

    def bits_of(self, x):
        return int.from_bytes(struct.pack(">" + self.pack, x), "big")

    def less(self, a, b):
        """a < b for non-NaN a, b, with -0 < +0."""
        x, y = self.value(a), self.value(b)
        if x != y:
            return x < y
        return (a & self.sign) != 0 and (b & self.sign) == 0

    def minmax(self, a, b, want_max):
        flags = NV if self.is_snan(a) or self.is_snan(b) else 0
        if self.is_nan(a) and self.is_nan(b):
            return self.qnan, flags
        if self.is_nan(a):
            return b, flags
        if self.is_nan(b):
            return a, flags
        if want_max:
            return (b if self.less(a, b) else a), flags
        return (b if self.less(b, a) else a), flags

    def fclass(self, v):
        s, e, m = self.parts(v)
        if e == self.emax:
            if m == 0:
                return 1 << (0 if s else 7)
            return 1 << (9 if v & self.qbit else 8)
        if e == 0:
            if m == 0:
                return 1 << (3 if s else 4)
            return 1 << (2 if s else 5)
        return 1 << (1 if s else 6)

    def hex(self, v):
        return "%0*X" % (self.digits, v)


F32 = Fmt("f32", 32, 8, "f")
F64 = Fmt("f64", 64, 11, "d")


def specials(f):
    """Signed zeros, subnormals, normals, infinities, quiet and signaling NaNs."""
    m = f.mbits
    top = f.emax << m
    pos = [
        0,                               # +0
        1,                               # smallest subnormal
        0x12345 << (m - 20),             # a subnormal
        (1 << m) - 1,                    # largest subnormal
        1 << m,                          # smallest normal
        (1 << m) + 1,
        f.bits_of(1.0),
        f.bits_of(1.0) + 1,              # 1 + ulp
        f.bits_of(1.5),
        f.bits_of(3.141592653589793),
        top - 1,                         # largest finite
        top,                             # +inf
    ]
    if f is F64:
        pos += [0x3FF00000FFFFFFFF, 0x3FF0000100000000]  # differ across the word boundary
    vals = pos + [v | f.sign for v in pos]
    vals += [f.qnan, f.qnan | f.sign, f.qnan | 1, f.sign - 1, (1 << f.bits) - 1]  # quiet NaNs
    vals += [top | 1, top | 1 | f.sign, top | (f.qbit - 1), (top | (f.qbit - 1)) | f.sign, top | (f.qbit >> 1)]  # signaling
    return vals


# riscv-tests
# -----------

MACROS = {
    "qNaNf": 0x7FC00000, "sNaNf": 0x7F800001, "Inff": 0x7F800000, "nInff": 0xFF800000,
    "qNaNd": 0x7FF8000000000000, "sNaNd": 0x7FF0000000000001,
    "Infd": 0x7FF0000000000000, "nInfd": 0xFFF0000000000000,
}


def operand(f, tok, is_hex):
    tok = tok.strip()
    if tok in MACROS:
        return MACROS[tok]
    if is_hex:
        return int(tok, 0)
    return f.bits_of(float(tok))  # NaN assembles to the canonical quiet NaN


def riscv_cases(root):
    """(fmt, op, operands, result, flags) for every fmin/fmax/fclass case."""
    out = []
    for sub, f, suffix in (("rv64uf", F32, "S"), ("rv64ud", F64, "D")):
        text = open(os.path.join(root, "isa", sub, "fmin.S")).read()
        pat = r"^\s*TEST_FP_OP2_%s(_HEX)?\(\s*\d+\s*,\s*f(min|max)\.\w\s*,([^)]*)\)" % suffix
        for m in re.finditer(pat, text, re.M):
            is_hex = m.group(1) is not None
            flags, res, a, b = [t.strip() for t in m.group(3).split(",")]
            out.append((f, m.group(2), [operand(f, a, is_hex), operand(f, b, is_hex)],
                        operand(f, res, is_hex), int(flags, 0)))
        text = open(os.path.join(root, "isa", sub, "fclass.S")).read()
        pat = r"^\s*TEST_FCLASS_%s\(\s*\d+\s*,\s*1\s*<<\s*(\d+)\s*,\s*(\w+)\s*\)" % suffix
        for m in re.finditer(pat, text, re.M):
            out.append((f, "class", [operand(f, m.group(2), True)], 1 << int(m.group(1)), 0))
    return out


def main():
    root, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    lines = {(f.name, op): [] for f in (F32, F64) for op in ("min", "max", "class")}

    def emit(f, op, ops, res, flags):
        lines[(f.name, op)].append(" ".join([f.hex(v) for v in ops] + [f.hex(res), "%02X" % flags]))

    def expect(f, op, ops):
        if op == "class":
            return f.fclass(ops[0]), 0
        return f.minmax(ops[0], ops[1], op == "max")

    checked = 0
    for f, op, ops, res, flags in riscv_cases(root):
        mine = expect(f, op, ops)
        if mine != (res, flags):
            sys.exit("special.py: riscv-tests %s_%s %s expects %s/%02X, the rules give %s/%02X"
                     % (f.name, op, [f.hex(v) for v in ops], f.hex(res), flags, f.hex(mine[0]), mine[1]))
        emit(f, op, ops, res, flags)
        checked += 1
    if checked < 40:
        sys.exit("special.py: found only %d riscv-tests cases" % checked)

    for f in (F32, F64):
        vals = specials(f)
        for a in vals:
            emit(f, "class", [a], *expect(f, "class", [a]))
            for b in vals:
                for op in ("min", "max"):
                    emit(f, op, [a, b], *expect(f, op, [a, b]))

    for (name, op), ls in lines.items():
        with open(os.path.join(outdir, "%s_%s.txt" % (name, op)), "w") as out:
            out.write("\n".join(ls) + "\n")
    print("special.py: %d riscv-tests cases agree with the rules" % checked)


if __name__ == "__main__":
    main()
