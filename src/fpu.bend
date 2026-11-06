import Base

# The floating-point unit of wiltee: IEEE 754 binary32 and binary64 with the
# RISC-V F and D semantics, as pure functions over U32 words (Bend has no
# 64-bit integers, and its F32 has no rounding modes or flags). Results and
# flags match Berkeley SoftFloat 3e specialized for RISC-V bit for bit;
# tests/fpu/run.sh checks them against TestFloat.
#
# binary32 values are U32 bit patterns; binary64 values are two words
# (h, l) = (bits 63..32, bits 31..0).
# rm: 0 RNE, 1 RTZ, 2 RDN, 3 RUP, 4 RMM (the caller resolves DYN).
# Flags use the fflags layout: NV 16, DZ 8, OF 4, UF 2, NX 1.
#
# Every operation returns an FR:
# - binary32 results: FR{0, bits, flags}; binary64: FR{hi, lo, flags}
# - compares: FR{0, 0 or 1, flags}; class: FR{0, mask, 0}
# - conversions to W/WU: FR{sign extension of bits, bits, flags};
#   to L/LU: FR{hi, lo, flags}
#
# Internally a significand is a U32 or a word pair, and an exponent is a U32
# read as a signed number. As in SoftFloat, round-and-pack takes a
# significand with its leading 1 one bit below the top (bit 30 of a word, or
# bit 62 of a pair) and the biased exponent minus one, so packing adds the
# leading 1 into the exponent field.

type FR is Data:
  FR{h: U32, l: U32, f: U32}

# Two words: a 64-bit value (h, l), or two results.
type W is Data:
  W{h: U32, l: U32}

# Three words: an exponent and a two-word significand.
type U3 is Data:
  U3{e: U32, h: U32, l: U32}

# Four words, most significant first: a 128-bit value.
type Q is Data:
  Q{a: U32, b: U32, c: U32, d: U32}

# The state of an integer conversion: sign, rounded magnitude (h, l),
# bad = out of range before the range check, nx = inexact.
type CV is Data:
  CV{s: U32, h: U32, l: U32, bad: U32, nx: U32}

def FR.h(r: FR) -> U32:
  FR{h, l, f} = r
  h

def FR.l(r: FR) -> U32:
  FR{h, l, f} = r
  l

def FR.f(r: FR) -> U32:
  FR{h, l, f} = r
  f

def W.h(w: W) -> U32:
  W{h, l} = w
  h

def W.l(w: W) -> U32:
  W{h, l} = w
  l

def U3.e(u: U3) -> U32:
  U3{e, h, l} = u
  e

def U3.h(u: U3) -> U32:
  U3{e, h, l} = u
  h

def U3.l(u: U3) -> U32:
  U3{e, h, l} = u
  l

def Q.a(q: Q) -> U32:
  Q{a, b, c, d} = q
  a

def Q.b(q: Q) -> U32:
  Q{a, b, c, d} = q
  b

def Q.c(q: Q) -> U32:
  Q{a, b, c, d} = q
  c

def Q.d(q: Q) -> U32:
  Q{a, b, c, d} = q
  d

# Words
# -----

def sel(+c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

def bsel(+c: Bool, +a: Bool, +b: Bool) -> Bool:
  match c:
    case True{}:
      a
    case False{}:
      b

def qsel(+c: Bool, +a: Q, +b: Q) -> Q:
  match c:
    case True{}:
      a
    case False{}:
      b

def bit(+c: Bool) -> U32:
  sel(c, 1, 0)

def nz(+a: U32) -> Bool:
  U32.is_ne(a, 0)

def isz(+a: U32) -> Bool:
  U32.is_eq(a, 0)

def isneg(+a: U32) -> Bool:
  U32.is_ge(a, 2147483648)

def slt(+a: U32, +b: U32) -> Bool:
  U32.is_lt(U32.xor(a, 2147483648), U32.xor(b, 2147483648))

# arithmetic shift right by one
def sra1(+a: U32) -> U32:
  U32.or(U32.shrn(a, 1n), U32.and(a, 2147483648))

# a << n and a >> n for any n (0 once n >= 32)
def shl(+a: U32, +n: U32) -> U32:
  sel(U32.is_lt(n, 32), U32.shln(a, U32.to_nat(U32.and(n, 31))), 0)

def shr(+a: U32, +n: U32) -> U32:
  sel(U32.is_lt(n, 32), U32.shrn(a, U32.to_nat(U32.and(n, 31))), 0)

# a >> n, with any 1 shifted out jammed into bit 0
def srj(+a: U32, +n: U32) -> U32:
  +r = shr(a, n)
  U32.or(r, bit(U32.is_ne(shl(r, n), a)))

# count leading zeros (32 for 0); U32.log2 compiles to the native clz
def clz(+x: U32) -> U32:
  sel(isz(x), 32, U32.sub(31, U32.from_nat(U32.log2(x))))

# high word of the 64-bit product, from 16-bit limbs
def mulhu(+a: U32, +b: U32) -> U32:
  +a0 = U32.and(a, 65535)
  +a1 = U32.shrn(a, 16n)
  +b0 = U32.and(b, 65535)
  +b1 = U32.shrn(b, 16n)
  +lh = U32.mul(a0, b1)
  +hl = U32.mul(a1, b0)
  +mid = U32.add(U32.add(U32.shrn(U32.mul(a0, b0), 16n), U32.and(lh, 65535)), U32.and(hl, 65535))
  U32.add(U32.add(U32.mul(a1, b1), U32.add(U32.shrn(lh, 16n), U32.shrn(hl, 16n))), U32.shrn(mid, 16n))

# Pairs (64-bit values)
# --------------------

def add64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  +l = U32.add(al, bl)
  W{U32.add(U32.add(ah, bh), bit(U32.is_lt(l, al))), l}

def sub64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  W{U32.sub(U32.sub(ah, bh), bit(U32.is_lt(al, bl))), U32.sub(al, bl)}

def lt64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.or(U32.is_lt(ah, bh), Bool.and(U32.is_eq(ah, bh), U32.is_lt(al, bl)))

def nz64(+h: U32, +l: U32) -> Bool:
  nz(U32.or(h, l))

# shifts by any n (0 once n >= 64)
def shl64(+h: U32, +l: U32, +n: U32) -> W:
  +big = U32.is_ge(n, 32)
  W{sel(big, shl(l, U32.sub(n, 32)), U32.or(shl(h, n), shr(l, U32.sub(32, n)))), sel(big, 0, shl(l, n))}

def shr64(+h: U32, +l: U32, +n: U32) -> W:
  +big = U32.is_ge(n, 32)
  W{sel(big, 0, shr(h, n)), sel(big, shr(h, U32.sub(n, 32)), U32.or(shr(l, n), shl(h, U32.sub(32, n))))}

# shift right, jamming any 1 shifted out into bit 0
def srj64(+h: U32, +l: U32, +n: U32) -> W:
  +r = shr64(h, l, n)
  +b = shl64(W.h(r), W.l(r), n)
  W{W.h(r), U32.or(W.l(r), bit(Bool.or(U32.is_ne(W.h(b), h), U32.is_ne(W.l(b), l))))}

def clz64(+h: U32, +l: U32) -> U32:
  sel(nz(h), clz(h), U32.add(32, clz(l)))

# full 128-bit product of two pairs
def mul64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Q:
  +h00 = mulhu(al, bl)
  +l01 = U32.mul(al, bh)
  +h01 = mulhu(al, bh)
  +l10 = U32.mul(ah, bl)
  +h10 = mulhu(ah, bl)
  +l11 = U32.mul(ah, bh)
  +s1 = U32.add(h00, l01)
  +w1 = U32.add(s1, l10)
  +c1 = U32.add(bit(U32.is_lt(s1, h00)), bit(U32.is_lt(w1, s1)))
  +s2 = U32.add(h01, h10)
  +s3 = U32.add(s2, l11)
  +w2 = U32.add(s3, c1)
  +c2 = U32.add(U32.add(bit(U32.is_lt(s2, h01)), bit(U32.is_lt(s3, s2))), bit(U32.is_lt(w2, s3)))
  Q{U32.add(mulhu(ah, bh), c2), w2, w1, U32.mul(al, bl)}

# Quads (128-bit values)
# ---------------------

def add128(+a3: U32, +a2: U32, +a1: U32, +a0: U32, +b3: U32, +b2: U32, +b1: U32, +b0: U32) -> Q:
  +lo = add64(a1, a0, b1, b0)
  +hi = add64(a3, a2, b3, b2)
  +hi2 = add64(W.h(hi), W.l(hi), 0, bit(lt64(W.h(lo), W.l(lo), a1, a0)))
  Q{W.h(hi2), W.l(hi2), W.h(lo), W.l(lo)}

def sub128(+a3: U32, +a2: U32, +a1: U32, +a0: U32, +b3: U32, +b2: U32, +b1: U32, +b0: U32) -> Q:
  +lo = sub64(a1, a0, b1, b0)
  +hi = sub64(a3, a2, b3, b2)
  +hi2 = sub64(W.h(hi), W.l(hi), 0, bit(lt64(a1, a0, b1, b0)))
  Q{W.h(hi2), W.l(hi2), W.h(lo), W.l(lo)}

# shift right by any n, jamming
def srj128(+a3: U32, +a2: U32, +a1: U32, +a0: U32, +n: U32) -> Q:
  +big = U32.is_ge(n, 64)
  +h = shr64(a3, a2, n)
  +lo = srj64(a1, a0, n)
  +cr = shl64(a3, a2, U32.sub(64, n))
  +lo2 = srj64(a3, a2, U32.sub(n, 64))
  +j = bit(nz64(a1, a0))
  Q{sel(big, 0, W.h(h)), sel(big, 0, W.l(h)), sel(big, W.h(lo2), U32.or(W.h(lo), W.h(cr))), sel(big, U32.or(W.l(lo2), j), U32.or(W.l(lo), W.l(cr)))}

# shift left by n < 64
def shl128(+a3: U32, +a2: U32, +a1: U32, +a0: U32, +n: U32) -> Q:
  +h = shl64(a3, a2, n)
  +c = shr64(a1, a0, U32.sub(64, n))
  +l = shl64(a1, a0, n)
  Q{U32.or(W.h(h), W.h(c)), U32.or(W.l(h), W.l(c)), W.h(l), W.l(l)}

# Shared pieces
# -------------

# SoftFloat's rounding increment: half for RNE and RMM, all round bits
# toward the infinity of the sign, 0 toward zero.
def rinc(+rm: U32, +s: U32, +half: U32, +full: U32) -> U32:
  match rm:
    case 1:
      0
    case 2:
      sel(nz(s), full, 0)
    case 3:
      sel(nz(s), 0, full)
    case _:
      half

# Conversions to integers. A value is split into an integer part (h, l) and
# a rounding word x (bit 31 is one half, the bits below are jammed).

# (h, l) >> n for any n, with the bits shifted out as a rounding word
def srx(+h: U32, +l: U32, +n: U32) -> U3:
  +v = shr64(h, l, n)
  +x = shl64(h, l, U32.sub(64, n))
  U3{sel(U32.is_gt(n, 64), bit(nz64(h, l)), U32.or(W.h(x), bit(nz(W.l(x))))), W.h(v), W.l(v)}

def cvt.up(+rm: U32, +s: U32, +l: U32, +x: U32) -> Bool:
  match rm:
    case 0:
      Bool.or(U32.is_gt(x, 2147483648), Bool.and(U32.is_eq(x, 2147483648), nz(U32.and(l, 1))))
    case 1:
      False{}
    case 2:
      Bool.and(nz(s), nz(x))
    case 3:
      Bool.and(isz(s), nz(x))
    case _:
      U32.is_ge(x, 2147483648)

# rounds the magnitude in v = U3{x, h, l}; bad: already out of range
def cvt.rnd(+s: U32, +bad: Bool, +v: U3, +rm: U32) -> CV:
  +i = bit(cvt.up(rm, s, U3.l(v), U3.e(v)))
  +m = add64(U3.h(v), U3.l(v), 0, i)
  CV{s, W.h(m), W.l(m), bit(Bool.or(bad, Bool.and(nz(i), Bool.not(nz64(W.h(m), W.l(m)))))), bit(nz(U3.e(v)))}

# Out of range or NaN: NV and the saturated value (a NaN comes with s = 0).
def cvt.i32(r: CV) -> FR:
  CV{+s, +h, +l, +bad, +nx} = r
  +ok = Bool.and(Bool.and(isz(bad), isz(h)), U32.is_lt(l, U32.add(2147483648, s)))
  +v = sel(ok, sel(nz(s), U32.sub(0, l), l), U32.add(2147483647, s))
  FR{sel(isneg(v), 4294967295, 0), v, sel(ok, nx, 16)}

def cvt.u32(r: CV) -> FR:
  CV{+s, +h, +l, +bad, +nx} = r
  +ok = Bool.and(Bool.and(isz(bad), isz(h)), Bool.or(isz(s), isz(l)))
  +v = sel(ok, l, sel(nz(s), 0, 4294967295))
  FR{sel(isneg(v), 4294967295, 0), v, sel(ok, nx, 16)}

def cvt.i64(r: CV) -> FR:
  CV{+s, +h, +l, +bad, +nx} = r
  +ok = Bool.and(isz(bad), Bool.or(U32.is_lt(h, 2147483648), Bool.and(nz(s), Bool.and(U32.is_eq(h, 2147483648), isz(l)))))
  +n = sub64(0, 0, h, l)
  FR{sel(ok, sel(nz(s), W.h(n), h), U32.add(2147483647, s)), sel(ok, sel(nz(s), W.l(n), l), sel(nz(s), 0, 4294967295)), sel(ok, nx, 16)}

def cvt.u64(r: CV) -> FR:
  CV{+s, +h, +l, +bad, +nx} = r
  +ok = Bool.and(isz(bad), Bool.or(isz(s), Bool.not(nz64(h, l))))
  +v = sel(nz(s), 0, 4294967295)
  FR{sel(ok, h, v), sel(ok, l, v), sel(ok, nx, 16)}

# binary32
# ========

def f32.e(+a: U32) -> U32:
  U32.and(U32.shrn(a, 23n), 255)

def f32.m(+a: U32) -> U32:
  U32.and(a, 8388607)

def f32.s(+a: U32) -> U32:
  U32.shrn(a, 31n)

def f32.isnan(+a: U32) -> Bool:
  U32.is_gt(U32.and(a, 2147483647), 2139095040)

def f32.issnan(+a: U32) -> Bool:
  Bool.and(f32.isnan(a), isz(U32.and(a, 4194304)))

def f32.isinf(+a: U32) -> Bool:
  U32.is_eq(U32.and(a, 2147483647), 2139095040)

def f32.iszero(+a: U32) -> Bool:
  isz(U32.and(a, 2147483647))

def f32.nan() -> U32:
  2143289344

# packToF32UI: the significand's leading 1 carries into the exponent
def f32.pk(+s: U32, +e: U32, +g: U32) -> U32:
  U32.add(U32.add(U32.shln(s, 31n), U32.shln(e, 23n)), g)

# exponent and significand (leading 1 at bit 23) of a finite nonzero value;
# a subnormal is normalized, its exponent dropping to 0 or below
def f32.unpk(+a: U32) -> W:
  +e = f32.e(a)
  +f = f32.m(a)
  +k = U32.sub(clz(f), 8)
  W{sel(nz(e), e, U32.sub(1, k)), sel(nz(e), U32.or(f, 8388608), shl(f, k))}

# Round and pack (SoftFloat's roundPackToF32): g has its leading 1 at bit 30
# and 7 round bits; e is the biased exponent minus 1. Tininess is detected
# after rounding.

def f32.rp.fin(+s: U32, +e: U32, +g: U32, +rm: U32, +inc: U32, +fl: U32) -> FR:
  +rb = U32.and(g, 127)
  +q = U32.shrn(U32.add(g, inc), 7n)
  +q2 = U32.and(q, U32.not(bit(Bool.and(U32.is_eq(rb, 64), isz(rm)))))
  FR{0, f32.pk(s, sel(nz(q2), e, 0), q2), U32.or(fl, bit(nz(rb)))}

# overflow: OF|NX and infinity, or the largest finite value when the mode
# rounds toward zero for this sign (inc = 0)
def f32.rp.hi(+o: Bool, +s: U32, +e: U32, +g: U32, +rm: U32, +inc: U32) -> FR:
  match o:
    case True{}:
      FR{0, U32.sub(f32.pk(s, 255, 0), bit(isz(inc))), 5}
    case False{}:
      f32.rp.fin(s, e, g, rm, inc, 0)

def f32.rp.lo(+s: U32, +e: U32, +g: U32, +rm: U32, +inc: U32) -> FR:
  +tiny = Bool.or(slt(e, 4294967295), U32.is_lt(U32.add(g, inc), 2147483648))
  +g2 = srj(g, U32.sub(0, e))
  f32.rp.fin(s, 0, g2, rm, inc, sel(Bool.and(tiny, nz(U32.and(g2, 127))), 2, 0))

def f32.rp.big(+neg: Bool, +s: U32, +e: U32, +g: U32, +rm: U32, +inc: U32) -> FR:
  match neg:
    case True{}:
      f32.rp.lo(s, e, g, rm, inc)
    case False{}:
      f32.rp.hi(Bool.or(U32.is_gt(e, 253), U32.is_ge(U32.add(g, inc), 2147483648)), s, e, g, rm, inc)

def f32.rp.go(+big: Bool, +s: U32, +e: U32, +g: U32, +rm: U32, +inc: U32) -> FR:
  match big:
    case True{}:
      f32.rp.big(isneg(e), s, e, g, rm, inc)
    case False{}:
      f32.rp.fin(s, e, g, rm, inc, 0)

def f32.rp(+s: U32, +e: U32, +g: U32, +rm: U32) -> FR:
  f32.rp.go(U32.is_ge(e, 253), s, e, g, rm, rinc(rm, s, 64, 127))

# the same for any g < 2^31: normalized first (g = 0 gives a zero)
def f32.nrp(+s: U32, +e: U32, +g: U32, +rm: U32) -> FR:
  +k = U32.sub(clz(g), 1)
  f32.rp(s, U32.sub(e, k), shl(g, k), rm)

# Add and subtract
# ----------------
# The operands are ordered by magnitude, so x has the larger exponent and
# the sign of any nonzero result. Both significands get 6 guard bits and y is
# aligned with jamming; a difference loses more than one leading bit only
# when the exponents differ by at most one, so nothing was jammed then.

def f32.add.sp(+x: U32, +y: U32) -> FR:
  +nan = f32.isnan(x)
  +inv = Bool.and(Bool.not(nan), U32.is_eq(U32.xor(x, y), 2147483648))
  FR{0, sel(Bool.or(nan, inv), f32.nan(), x), sel(Bool.or(inv, Bool.or(f32.issnan(x), f32.issnan(y))), 16, 0)}

def f32.add.fin(+x: U32, +y: U32, +rm: U32) -> FR:
  +ex = f32.e(x)
  +ey = f32.e(y)
  +ex1 = sel(nz(ex), ex, 1)
  +gx = U32.shln(U32.or(f32.m(x), sel(nz(ex), 8388608, 0)), 6n)
  +gy = srj(U32.shln(U32.or(f32.m(y), sel(nz(ey), 8388608, 0)), 6n), U32.sub(ex1, sel(nz(ey), ey, 1)))
  +same = isz(U32.and(U32.xor(x, y), 2147483648))
  +g = sel(same, U32.add(gx, gy), U32.sub(gx, gy))
  f32.nrp(sel(Bool.or(same, nz(g)), f32.s(x), bit(U32.is_eq(rm, 2))), ex1, g, rm)

def f32.add.go(+sp: Bool, +x: U32, +y: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f32.add.sp(x, y)
    case False{}:
      f32.add.fin(x, y, rm)

def f32.add.o(+x: U32, +y: U32, +rm: U32) -> FR:
  f32.add.go(U32.is_eq(f32.e(x), 255), x, y, rm)

def f32.add(+a: U32, +b: U32, +rm: U32) -> FR:
  +sw = U32.is_lt(U32.and(a, 2147483647), U32.and(b, 2147483647))
  f32.add.o(sel(sw, b, a), sel(sw, a, b), rm)

def f32.sub(+a: U32, +b: U32, +rm: U32) -> FR:
  f32.add(a, U32.xor(b, 2147483648), rm)

# Multiply
# --------

def f32.mul.sp(+a: U32, +b: U32, +s: U32) -> FR:
  +nan = Bool.or(f32.isnan(a), f32.isnan(b))
  +inv = Bool.and(Bool.not(nan), Bool.or(f32.iszero(a), f32.iszero(b)))
  FR{0, sel(Bool.or(nan, inv), f32.nan(), f32.pk(s, 255, 0)), sel(Bool.or(inv, Bool.or(f32.issnan(a), f32.issnan(b))), 16, 0)}

def f32.mul.fin(+a: U32, +b: U32, +s: U32, +rm: U32) -> FR:
  +ua = f32.unpk(a)
  +ub = f32.unpk(b)
  +x = U32.shln(W.l(ua), 7n)
  +y = U32.shln(W.l(ub), 8n)
  f32.nrp(s, U32.sub(U32.add(W.h(ua), W.h(ub)), 127), U32.or(mulhu(x, y), bit(nz(U32.mul(x, y)))), rm)

def f32.mul.z(+z: Bool, +a: U32, +b: U32, +s: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      FR{0, U32.shln(s, 31n), 0}
    case False{}:
      f32.mul.fin(a, b, s, rm)

def f32.mul.go(+sp: Bool, +a: U32, +b: U32, +s: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f32.mul.sp(a, b, s)
    case False{}:
      f32.mul.z(Bool.or(f32.iszero(a), f32.iszero(b)), a, b, s, rm)

def f32.mul(+a: U32, +b: U32, +rm: U32) -> FR:
  f32.mul.go(Bool.or(U32.is_eq(f32.e(a), 255), U32.is_eq(f32.e(b), 255)), a, b, f32.s(U32.xor(a, b)), rm)

# Divide
# ------

# an operand is NaN, infinite or zero
def f32.div.sp(+a: U32, +b: U32, +s: U32) -> FR:
  +nan = Bool.or(f32.isnan(a), f32.isnan(b))
  +ai = f32.isinf(a)
  +az = f32.iszero(a)
  +bz = f32.iszero(b)
  +inv = Bool.or(Bool.and(ai, f32.isinf(b)), Bool.and(az, bz))
  +dz = Bool.and(bz, Bool.not(Bool.or(Bool.or(az, ai), nan)))
  FR{0, sel(Bool.or(nan, inv), f32.nan(), f32.pk(s, sel(Bool.or(ai, bz), 255, 0), 0)), sel(Bool.or(inv, Bool.or(f32.issnan(a), f32.issnan(b))), 16, sel(dz, 8, 0))}

# one long-division step of n quotient bits: W{quotient, remainder}
def f32.div.st(+q: U32, +r: U32, +d: U32, +n: Nat) -> W:
  +r2 = U32.shln(r, n)
  +t = U32.div(r2, d)
  W{U32.or(U32.shln(q, n), t), U32.sub(r2, U32.mul(t, d))}

def f32.div.fin(+a: U32, +b: U32, +s: U32, +rm: U32) -> FR:
  +ua = f32.unpk(a)
  +ub = f32.unpk(b)
  +mb = W.l(ub)
  +lt = U32.is_lt(W.l(ua), mb)
  +ma = sel(lt, U32.shln(W.l(ua), 1n), W.l(ua))
  +w1 = f32.div.st(1, U32.sub(ma, mb), mb, 8n)
  +w2 = f32.div.st(W.h(w1), W.l(w1), mb, 8n)
  +w3 = f32.div.st(W.h(w2), W.l(w2), mb, 8n)
  +w4 = f32.div.st(W.h(w3), W.l(w3), mb, 6n)
  f32.rp(s, U32.sub(U32.add(U32.sub(W.h(ua), W.h(ub)), 126), bit(lt)), U32.or(W.h(w4), bit(nz(W.l(w4)))), rm)

def f32.div.go(+sp: Bool, +a: U32, +b: U32, +s: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f32.div.sp(a, b, s)
    case False{}:
      f32.div.fin(a, b, s, rm)

def f32.div(+a: U32, +b: U32, +rm: U32) -> FR:
  +sp = Bool.or(Bool.or(U32.is_eq(f32.e(a), 255), U32.is_eq(f32.e(b), 255)), Bool.or(f32.iszero(a), f32.iszero(b)))
  f32.div.go(sp, a, b, f32.s(U32.xor(a, b)), rm)

# Square root
# -----------

# NaN, +inf, a zero or a negative value
def f32.sqrt.sp(+a: U32) -> FR:
  +ok = Bool.or(f32.iszero(a), U32.is_eq(a, 2139095040))
  FR{0, sel(ok, a, f32.nan()), sel(Bool.or(f32.issnan(a), Bool.not(Bool.or(ok, f32.isnan(a)))), 16, 0)}

# Square root, digit by digit, in one word: n steps, each taking the next
# two bits of the radicand from the top of x; q the root so far, r the
# remainder (the root stays below 2^26, so 4r + 3 fits). Returns the root
# with its leading 1 moved to bit 30 and a nonzero remainder as sticky bit.
def f32.sqrt.loop(n: Nat, +x: U32, +q: U32, +r: U32) -> U32:
  match n:
    case 0n:
      U32.or(U32.shln(q, 5n), bit(nz(r)))
    case 1n+p:
      +r4 = U32.or(U32.shln(r, 2n), U32.shrn(x, 30n))
      +t = U32.or(U32.shln(q, 2n), 1)
      +ge = U32.is_ge(r4, t)
      f32.sqrt.loop(p, U32.shln(x, 2n), U32.or(U32.shln(q, 1n), bit(ge)), sel(ge, U32.sub(r4, t), r4))

# The radicand m * 2^(27 or 28) gives a 26-bit root: 24 bits, a round bit
# and one more.
def f32.sqrt.fin(+a: U32, +rm: U32) -> FR:
  +u = f32.unpk(a)
  +e = W.h(u)
  +x = U32.shln(W.l(u), U32.to_nat(sel(isz(U32.and(e, 1)), 8, 7)))
  f32.rp(0, U32.add(sra1(U32.sub(e, 127)), 126), f32.sqrt.loop(26n, x, 0, 0), rm)

def f32.sqrt.go(+sp: Bool, +a: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f32.sqrt.sp(a)
    case False{}:
      f32.sqrt.fin(a, rm)

def f32.sqrt(+a: U32, +rm: U32) -> FR:
  f32.sqrt.go(Bool.or(U32.is_ge(a, 2139095040), f32.iszero(a)), a, rm)

# Fused multiply-add (SoftFloat's mulAddF32)
# -----------------------------------------

# an operand is NaN or infinite; inf * 0 is invalid even when c is a quiet NaN
def f32.fma.sp(+a: U32, +b: U32, +c: U32) -> FR:
  +ps = f32.s(U32.xor(a, b))
  +abnan = Bool.or(f32.isnan(a), f32.isnan(b))
  +abinf = Bool.and(Bool.not(abnan), Bool.or(f32.isinf(a), f32.isinf(b)))
  +invp = Bool.and(abinf, Bool.or(f32.iszero(a), f32.iszero(b)))
  +invs = Bool.and(Bool.and(abinf, Bool.not(invp)), Bool.and(f32.isinf(c), U32.is_ne(f32.s(c), ps)))
  +inv = Bool.or(invp, invs)
  +nan = Bool.or(Bool.or(abnan, f32.isnan(c)), inv)
  +snan = Bool.or(Bool.or(f32.issnan(a), f32.issnan(b)), f32.issnan(c))
  FR{0, sel(nan, f32.nan(), sel(abinf, f32.pk(ps, 255, 0), c)), sel(Bool.or(snan, inv), 16, 0)}

# a or b is zero, c finite
def f32.fma.zp(+a: U32, +b: U32, +c: U32, +rm: U32) -> FR:
  +cancel = Bool.and(f32.iszero(c), U32.is_ne(f32.s(U32.xor(a, b)), f32.s(c)))
  FR{0, sel(cancel, U32.shln(bit(U32.is_eq(rm, 2)), 31n), c), 0}

# s, e: sign and exponent of the 64-bit significand (zh, zl) before
# normalization
def f32.fma.nrm(+s: U32, +e: U32, +zh: U32, +zl: U32, +rm: U32) -> FR:
  +k = U32.sub(clz64(zh, zl), 1)
  +n = shl64(zh, zl, k)
  f32.rp(s, U32.sub(e, k), U32.or(W.h(n), bit(nz(W.l(n)))), rm)

def f32.fma.eq0(+z: Bool, +s: U32, +e: U32, +zh: U32, +zl: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      FR{0, U32.shln(bit(U32.is_eq(rm, 2)), 31n), 0}
    case False{}:
      +ng = isneg(zh)
      +w = sub64(0, 0, zh, zl)
      f32.fma.nrm(U32.xor(s, bit(ng)), e, sel(ng, W.h(w), zh), sel(ng, W.l(w), zl), rm)

# opposite signs; c3 is 0, 1, 2 as d = ep - ec is below, at or above 0
def f32.fma.sub(+c3: U32, +s: U32, +sc: U32, +ep: U32, +ph: U32, +pl: U32, +ec: U32, +gc: U32, +d: U32, +rm: U32) -> FR:
  match c3:
    case 0:
      +y = srj64(ph, pl, U32.sub(0, d))
      +z = sub64(gc, 0, W.h(y), W.l(y))
      f32.fma.nrm(sc, ec, W.h(z), W.l(z), rm)
    case 1:
      +z = sub64(ph, pl, gc, 0)
      f32.fma.eq0(Bool.not(nz64(W.h(z), W.l(z))), s, ep, W.h(z), W.l(z), rm)
    case _:
      +y = srj64(gc, 0, d)
      +z = sub64(ph, pl, W.h(y), W.l(y))
      f32.fma.nrm(s, ep, W.h(z), W.l(z), rm)

# equal signs
def f32.fma.add(+le: Bool, +s: U32, +ep: U32, +ph: U32, +pl: U32, +ec: U32, +gc: U32, +d: U32, +rm: U32) -> FR:
  match le:
    case True{}:
      f32.nrp(s, ec, U32.add(gc, W.l(srj64(ph, pl, U32.sub(32, d)))), rm)
    case False{}:
      +y = srj64(gc, 0, d)
      +z = add64(ph, pl, W.h(y), W.l(y))
      f32.nrp(s, ep, U32.or(W.h(z), bit(nz(W.l(z)))), rm)

def f32.fma.c2(+same: Bool, +c3: U32, +s: U32, +sc: U32, +ep: U32, +ph: U32, +pl: U32, +ec: U32, +gc: U32, +d: U32, +rm: U32) -> FR:
  match same:
    case True{}:
      f32.fma.add(U32.is_lt(c3, 2), s, ep, ph, pl, ec, gc, d, rm)
    case False{}:
      f32.fma.sub(c3, s, sc, ep, ph, pl, ec, gc, d, rm)

# the product (ph, pl) has its leading 1 at bit 61 and exponent ep
def f32.fma.c(+cz: Bool, +s: U32, +ep: U32, +ph: U32, +pl: U32, +c: U32, +rm: U32) -> FR:
  match cz:
    case True{}:
      f32.rp(s, U32.sub(ep, 1), U32.or(U32.or(U32.shln(ph, 1n), U32.shrn(pl, 31n)), bit(nz(U32.and(pl, 2147483647)))), rm)
    case False{}:
      +uc = f32.unpk(c)
      +d = U32.sub(ep, W.h(uc))
      +sc = f32.s(c)
      f32.fma.c2(U32.is_eq(s, sc), sel(isneg(d), 0, sel(isz(d), 1, 2)), s, sc, ep, ph, pl, W.h(uc), U32.shln(W.l(uc), 6n), d, rm)

def f32.fma.fin(+a: U32, +b: U32, +c: U32, +rm: U32) -> FR:
  +ua = f32.unpk(a)
  +ub = f32.unpk(b)
  +x = U32.shln(W.l(ua), 7n)
  +y = U32.shln(W.l(ub), 7n)
  +ph = mulhu(x, y)
  +lo = U32.is_lt(ph, 536870912)
  +p = shl64(ph, U32.mul(x, y), bit(lo))
  f32.fma.c(f32.iszero(c), f32.s(U32.xor(a, b)), U32.sub(U32.sub(U32.add(W.h(ua), W.h(ub)), 126), bit(lo)), W.h(p), W.l(p), c, rm)

def f32.fma.z(+z: Bool, +a: U32, +b: U32, +c: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      f32.fma.zp(a, b, c, rm)
    case False{}:
      f32.fma.fin(a, b, c, rm)

def f32.fma.go(+sp: Bool, +a: U32, +b: U32, +c: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f32.fma.sp(a, b, c)
    case False{}:
      f32.fma.z(Bool.or(f32.iszero(a), f32.iszero(b)), a, b, c, rm)

def f32.fma(+a: U32, +b: U32, +c: U32, +rm: U32) -> FR:
  +sp = Bool.or(Bool.or(U32.is_eq(f32.e(a), 255), U32.is_eq(f32.e(b), 255)), U32.is_eq(f32.e(c), 255))
  f32.fma.go(sp, a, b, c, rm)

# Compare, min, max, class
# ------------------------

def f32.eq(+a: U32, +b: U32) -> FR:
  +nan = Bool.or(f32.isnan(a), f32.isnan(b))
  +eq = Bool.or(U32.is_eq(a, b), isz(U32.shln(U32.or(a, b), 1n)))
  FR{0, bit(Bool.and(Bool.not(nan), eq)), sel(Bool.or(f32.issnan(a), f32.issnan(b)), 16, 0)}

def f32.lt(+a: U32, +b: U32) -> FR:
  +nan = Bool.or(f32.isnan(a), f32.isnan(b))
  +sa = isneg(a)
  +lt = bsel(Bool.xor(sa, isneg(b)), Bool.and(sa, nz(U32.shln(U32.or(a, b), 1n))), Bool.and(U32.is_ne(a, b), Bool.xor(sa, U32.is_lt(a, b))))
  FR{0, bit(Bool.and(Bool.not(nan), lt)), sel(nan, 16, 0)}

def f32.le(+a: U32, +b: U32) -> FR:
  +nan = Bool.or(f32.isnan(a), f32.isnan(b))
  +sa = isneg(a)
  +le = bsel(Bool.xor(sa, isneg(b)), Bool.or(sa, isz(U32.shln(U32.or(a, b), 1n))), Bool.or(U32.is_eq(a, b), Bool.xor(sa, U32.is_lt(a, b))))
  FR{0, bit(Bool.and(Bool.not(nan), le)), sel(nan, 16, 0)}

# a < b for non-NaN values, with -0 < +0
def f32.lt.tot(+a: U32, +b: U32) -> Bool:
  +sa = isneg(a)
  bsel(Bool.xor(sa, isneg(b)), sa, Bool.and(U32.is_ne(a, b), Bool.xor(sa, U32.is_lt(a, b))))

# minimumNumber / maximumNumber: a NaN loses to a number; two NaNs give the
# canonical NaN; NV for a signaling NaN. pa: a wins among numbers.
def f32.mm(+a: U32, +b: U32, +pa: Bool) -> FR:
  +an = f32.isnan(a)
  +bn = f32.isnan(b)
  FR{0, sel(Bool.and(an, bn), f32.nan(), sel(an, b, sel(bn, a, sel(pa, a, b)))), sel(Bool.or(f32.issnan(a), f32.issnan(b)), 16, 0)}

def f32.min(+a: U32, +b: U32) -> FR:
  f32.mm(a, b, f32.lt.tot(a, b))

def f32.max(+a: U32, +b: U32) -> FR:
  f32.mm(a, b, f32.lt.tot(b, a))

# bit 0 -inf, 1 -normal, 2 -subnormal, 3 -0, 4 +0, 5 +subnormal, 6 +normal,
# 7 +inf, 8 signaling NaN, 9 quiet NaN
def f32.class(+a: U32) -> FR:
  +e = f32.e(a)
  +f = f32.m(a)
  +s = isneg(a)
  +i = sel(U32.is_eq(e, 255), sel(isz(f), sel(s, 0, 7), sel(nz(U32.and(f, 4194304)), 9, 8)), sel(isz(e), sel(isz(f), sel(s, 3, 4), sel(s, 2, 5)), sel(s, 1, 6)))
  FR{0, U32.shln(1, U32.to_nat(i)), 0}

# Conversions
# -----------

# |a| = m * 2^(e - 150): m << 40 as a pair, shifted right by 190 - e
def f32.toint(+a: U32, +rm: U32) -> CV:
  +e = f32.e(a)
  +m = U32.or(f32.m(a), sel(nz(e), 8388608, 0))
  +s = bit(Bool.and(isneg(a), Bool.not(f32.isnan(a))))
  cvt.rnd(s, U32.is_gt(e, 190), srx(U32.shln(m, 8n), 0, U32.sub(190, e)), rm)

def f32.to_i32(+a: U32, +rm: U32) -> FR:
  cvt.i32(f32.toint(a, rm))

def f32.to_u32(+a: U32, +rm: U32) -> FR:
  cvt.u32(f32.toint(a, rm))

def f32.to_i64(+a: U32, +rm: U32) -> FR:
  cvt.i64(f32.toint(a, rm))

def f32.to_u64(+a: U32, +rm: U32) -> FR:
  cvt.u64(f32.toint(a, rm))

# sign s and magnitude (h, l), rounded
def f32.ofm(+s: U32, +h: U32, +l: U32, +rm: U32) -> FR:
  +k = clz64(h, l)
  +n = shl64(h, l, k)
  f32.rp(s, U32.sub(189, k), U32.or(U32.shrn(W.h(n), 1n), bit(Bool.or(nz(U32.and(W.h(n), 1)), nz(W.l(n))))), rm)

def f32.of_u64(+h: U32, +l: U32, +rm: U32) -> FR:
  f32.ofm(0, h, l, rm)

def f32.of_i64(+h: U32, +l: U32, +rm: U32) -> FR:
  +s = isneg(h)
  +n = sub64(0, 0, h, l)
  f32.ofm(bit(s), sel(s, W.h(n), h), sel(s, W.l(n), l), rm)

def f32.of_u32(+v: U32, +rm: U32) -> FR:
  f32.ofm(0, 0, v, rm)

def f32.of_i32(+v: U32, +rm: U32) -> FR:
  +s = isneg(v)
  f32.ofm(bit(s), 0, sel(s, U32.sub(0, v), v), rm)

# exact
def f32.to_f64.sp(+a: U32) -> FR:
  FR{sel(f32.isnan(a), 2146959360, U32.or(U32.and(a, 2147483648), 2146435072)), 0, sel(f32.issnan(a), 16, 0)}

def f32.to_f64.fin(+a: U32) -> FR:
  +u = f32.unpk(a)
  +m = W.l(u)
  FR{U32.or(U32.and(a, 2147483648), U32.or(U32.shln(U32.add(W.h(u), 896), 20n), U32.shrn(U32.and(m, 8388607), 3n))), U32.shln(m, 29n), 0}

def f32.to_f64.z(+z: Bool, +a: U32) -> FR:
  match z:
    case True{}:
      FR{a, 0, 0}
    case False{}:
      f32.to_f64.fin(a)

def f32.to_f64.go(+sp: Bool, +a: U32) -> FR:
  match sp:
    case True{}:
      f32.to_f64.sp(a)
    case False{}:
      f32.to_f64.z(f32.iszero(a), a)

def f32.to_f64(+a: U32) -> FR:
  f32.to_f64.go(U32.is_eq(f32.e(a), 255), a)

# rounds per rm
def f64.to_f32.z(+z: Bool, +s: U32, +e: U32, +g: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      FR{0, U32.shln(s, 31n), 0}
    case False{}:
      f32.rp(s, U32.sub(e, 897), U32.or(g, 1073741824), rm)

def f64.to_f32.fin(+h: U32, +l: U32, +rm: U32) -> FR:
  +e = U32.and(U32.shrn(h, 20n), 2047)
  +g = U32.or(U32.or(U32.shln(U32.and(h, 1048575), 10n), U32.shrn(l, 22n)), bit(nz(U32.and(l, 4194303))))
  f64.to_f32.z(Bool.and(isz(e), isz(g)), U32.shrn(h, 31n), e, g, rm)

# binary64
# ========

def f64.e(+h: U32) -> U32:
  U32.and(U32.shrn(h, 20n), 2047)

def f64.mh(+h: U32) -> U32:
  U32.and(h, 1048575)

def f64.isnan(+h: U32, +l: U32) -> Bool:
  +a = U32.and(h, 2147483647)
  Bool.or(U32.is_gt(a, 2146435072), Bool.and(U32.is_eq(a, 2146435072), nz(l)))

def f64.issnan(+h: U32, +l: U32) -> Bool:
  Bool.and(f64.isnan(h, l), isz(U32.and(h, 524288)))

def f64.isinf(+h: U32, +l: U32) -> Bool:
  Bool.and(U32.is_eq(U32.and(h, 2147483647), 2146435072), isz(l))

def f64.iszero(+h: U32, +l: U32) -> Bool:
  Bool.and(isz(U32.and(h, 2147483647)), isz(l))

def f64.nan() -> U32:
  2146959360

# high word of packToF64UI, given the significand's high word
def f64.pk(+s: U32, +e: U32, +gh: U32) -> U32:
  U32.add(U32.add(U32.shln(s, 31n), U32.shln(e, 20n)), gh)

# exponent and significand (leading 1 at bit 52) of a finite nonzero value
def f64.unpk(+h: U32, +l: U32) -> U3:
  +e = f64.e(h)
  +fh = f64.mh(h)
  +k = U32.sub(clz64(fh, l), 11)
  +n = shl64(fh, l, k)
  U3{sel(nz(e), e, U32.sub(1, k)), sel(nz(e), U32.or(fh, 1048576), W.h(n)), sel(nz(e), l, W.l(n))}

# m << 9, m << 10, m << 11 for a significand from unpk
def f64.g9(+u: U3) -> W:
  W{U32.or(U32.shln(U3.h(u), 9n), U32.shrn(U3.l(u), 23n)), U32.shln(U3.l(u), 9n)}

def f64.g10(+u: U3) -> W:
  W{U32.or(U32.shln(U3.h(u), 10n), U32.shrn(U3.l(u), 22n)), U32.shln(U3.l(u), 10n)}

def f64.g11(+u: U3) -> W:
  W{U32.or(U32.shln(U3.h(u), 11n), U32.shrn(U3.l(u), 21n)), U32.shln(U3.l(u), 11n)}

# Round and pack (SoftFloat's roundPackToF64): (gh, gl) has its leading 1 at
# bit 62 and 10 round bits; e is the biased exponent minus 1.

def f64.rp.fin(+s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32, +inc: U32, +fl: U32) -> FR:
  +rb = U32.and(gl, 1023)
  +t = add64(gh, gl, 0, inc)
  +qh = U32.shrn(W.h(t), 10n)
  +ql = U32.and(U32.or(U32.shrn(W.l(t), 10n), U32.shln(W.h(t), 22n)), U32.not(bit(Bool.and(U32.is_eq(rb, 512), isz(rm)))))
  FR{f64.pk(s, sel(nz64(qh, ql), e, 0), qh), ql, U32.or(fl, bit(nz(rb)))}

# overflow, as for binary32
def f64.rp.hi(+o: Bool, +s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32, +inc: U32) -> FR:
  match o:
    case True{}:
      +z = isz(inc)
      FR{U32.sub(f64.pk(s, 2047, 0), bit(z)), sel(z, 4294967295, 0), 5}
    case False{}:
      f64.rp.fin(s, e, gh, gl, rm, inc, 0)

def f64.rp.lo(+s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32, +inc: U32) -> FR:
  +tiny = Bool.or(slt(e, 4294967295), U32.is_lt(W.h(add64(gh, gl, 0, inc)), 2147483648))
  +g = srj64(gh, gl, U32.sub(0, e))
  f64.rp.fin(s, 0, W.h(g), W.l(g), rm, inc, sel(Bool.and(tiny, nz(U32.and(W.l(g), 1023))), 2, 0))

def f64.rp.big(+neg: Bool, +s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32, +inc: U32) -> FR:
  match neg:
    case True{}:
      f64.rp.lo(s, e, gh, gl, rm, inc)
    case False{}:
      f64.rp.hi(Bool.or(U32.is_gt(e, 2045), isneg(W.h(add64(gh, gl, 0, inc)))), s, e, gh, gl, rm, inc)

def f64.rp.go(+big: Bool, +s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32, +inc: U32) -> FR:
  match big:
    case True{}:
      f64.rp.big(isneg(e), s, e, gh, gl, rm, inc)
    case False{}:
      f64.rp.fin(s, e, gh, gl, rm, inc, 0)

def f64.rp(+s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32) -> FR:
  f64.rp.go(U32.is_ge(e, 2045), s, e, gh, gl, rm, rinc(rm, s, 512, 1023))

# the same for any significand below 2^63: normalized first
def f64.nrp(+s: U32, +e: U32, +gh: U32, +gl: U32, +rm: U32) -> FR:
  +k = U32.sub(clz64(gh, gl), 1)
  +n = shl64(gh, gl, k)
  f64.rp(s, U32.sub(e, k), W.h(n), W.l(n), rm)

# Add and subtract (operands ordered by magnitude as for binary32, 9 guard bits)
# -----------------------------------------------------------------

def f64.add.sp(+xh: U32, +xl: U32, +yh: U32, +yl: U32) -> FR:
  +nan = f64.isnan(xh, xl)
  +inv = Bool.and(Bool.not(nan), Bool.and(U32.is_eq(U32.xor(xh, yh), 2147483648), U32.is_eq(xl, yl)))
  +bad = Bool.or(nan, inv)
  FR{sel(bad, f64.nan(), xh), sel(bad, 0, xl), sel(Bool.or(inv, Bool.or(f64.issnan(xh, xl), f64.issnan(yh, yl))), 16, 0)}

def f64.add.fin(+xh: U32, +xl: U32, +yh: U32, +yl: U32, +rm: U32) -> FR:
  +ex = f64.e(xh)
  +ey = f64.e(yh)
  +ex1 = sel(nz(ex), ex, 1)
  +mxh = U32.or(f64.mh(xh), sel(nz(ex), 1048576, 0))
  +myh = U32.or(f64.mh(yh), sel(nz(ey), 1048576, 0))
  +gxh = U32.or(U32.shln(mxh, 9n), U32.shrn(xl, 23n))
  +gxl = U32.shln(xl, 9n)
  +gy = srj64(U32.or(U32.shln(myh, 9n), U32.shrn(yl, 23n)), U32.shln(yl, 9n), U32.sub(ex1, sel(nz(ey), ey, 1)))
  +same = isz(U32.and(U32.xor(xh, yh), 2147483648))
  +sm = add64(gxh, gxl, W.h(gy), W.l(gy))
  +df = sub64(gxh, gxl, W.h(gy), W.l(gy))
  +gh = sel(same, W.h(sm), W.h(df))
  +gl = sel(same, W.l(sm), W.l(df))
  f64.nrp(sel(Bool.or(same, nz64(gh, gl)), U32.shrn(xh, 31n), bit(U32.is_eq(rm, 2))), ex1, gh, gl, rm)

def f64.add.go(+sp: Bool, +xh: U32, +xl: U32, +yh: U32, +yl: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.add.sp(xh, xl, yh, yl)
    case False{}:
      f64.add.fin(xh, xl, yh, yl, rm)

def f64.add.o(+xh: U32, +xl: U32, +yh: U32, +yl: U32, +rm: U32) -> FR:
  f64.add.go(U32.is_eq(f64.e(xh), 2047), xh, xl, yh, yl, rm)

def f64.add(+ah: U32, +al: U32, +bh: U32, +bl: U32, +rm: U32) -> FR:
  +sw = lt64(U32.and(ah, 2147483647), al, U32.and(bh, 2147483647), bl)
  f64.add.o(sel(sw, bh, ah), sel(sw, bl, al), sel(sw, ah, bh), sel(sw, al, bl), rm)

def f64.sub(+ah: U32, +al: U32, +bh: U32, +bl: U32, +rm: U32) -> FR:
  f64.add(ah, al, U32.xor(bh, 2147483648), bl, rm)

# Multiply
# --------

def f64.mul.sp(+ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32) -> FR:
  +nan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +inv = Bool.and(Bool.not(nan), Bool.or(f64.iszero(ah, al), f64.iszero(bh, bl)))
  +bad = Bool.or(nan, inv)
  FR{sel(bad, f64.nan(), f64.pk(s, 2047, 0)), 0, sel(Bool.or(inv, Bool.or(f64.issnan(ah, al), f64.issnan(bh, bl))), 16, 0)}

def f64.mul.fin(+ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32, +rm: U32) -> FR:
  +ua = f64.unpk(ah, al)
  +ub = f64.unpk(bh, bl)
  +x = f64.g10(ua)
  +y = f64.g11(ub)
  +p = mul64(W.h(x), W.l(x), W.h(y), W.l(y))
  f64.nrp(s, U32.sub(U32.add(U3.e(ua), U3.e(ub)), 1023), Q.a(p), U32.or(Q.b(p), bit(nz64(Q.c(p), Q.d(p)))), rm)

def f64.mul.z(+z: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      FR{U32.shln(s, 31n), 0, 0}
    case False{}:
      f64.mul.fin(ah, al, bh, bl, s, rm)

def f64.mul.go(+sp: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.mul.sp(ah, al, bh, bl, s)
    case False{}:
      f64.mul.z(Bool.or(f64.iszero(ah, al), f64.iszero(bh, bl)), ah, al, bh, bl, s, rm)

def f64.mul(+ah: U32, +al: U32, +bh: U32, +bl: U32, +rm: U32) -> FR:
  f64.mul.go(Bool.or(U32.is_eq(f64.e(ah), 2047), U32.is_eq(f64.e(bh), 2047)), ah, al, bh, bl, U32.shrn(U32.xor(ah, bh), 31n), rm)

# Divide
# ------

def f64.div.sp(+ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32) -> FR:
  +nan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +ai = f64.isinf(ah, al)
  +az = f64.iszero(ah, al)
  +bz = f64.iszero(bh, bl)
  +inv = Bool.or(Bool.and(ai, f64.isinf(bh, bl)), Bool.and(az, bz))
  +dz = Bool.and(bz, Bool.not(Bool.or(Bool.or(az, ai), nan)))
  FR{sel(Bool.or(nan, inv), f64.nan(), f64.pk(s, sel(Bool.or(ai, bz), 2047, 0), 0)), 0, sel(Bool.or(inv, Bool.or(f64.issnan(ah, al), f64.issnan(bh, bl))), 16, sel(dz, 8, 0))}

# restoring division, one quotient bit a step: Q{qh, ql, rh, rl}
def f64.div.go(n: Nat, +rh: U32, +rl: U32, +dh: U32, +dl: U32, +qh: U32, +ql: U32) -> Q:
  match n:
    case 0n:
      Q{qh, ql, rh, rl}
    case 1n+p:
      +ge = Bool.not(lt64(rh, rl, dh, dl))
      +t = sub64(rh, rl, dh, dl)
      +r2h = sel(ge, W.h(t), rh)
      +r2l = sel(ge, W.l(t), rl)
      f64.div.go(p, U32.or(U32.shln(r2h, 1n), U32.shrn(r2l, 31n)), U32.shln(r2l, 1n), dh, dl, U32.or(U32.shln(qh, 1n), U32.shrn(ql, 31n)), U32.or(U32.shln(ql, 1n), bit(ge)))

# 55 quotient bits of ma / mb (ma first doubled if below mb), then sticky
def f64.div.fin(+ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32, +rm: U32) -> FR:
  +ua = f64.unpk(ah, al)
  +ub = f64.unpk(bh, bl)
  +lt = lt64(U3.h(ua), U3.l(ua), U3.h(ub), U3.l(ub))
  +ma = shl64(U3.h(ua), U3.l(ua), bit(lt))
  +q = f64.div.go(55n, W.h(ma), W.l(ma), U3.h(ub), U3.l(ub), 0, 0)
  +g = shl64(Q.a(q), U32.or(Q.b(q), bit(nz64(Q.c(q), Q.d(q)))), 8)
  f64.rp(s, U32.sub(U32.add(U32.sub(U3.e(ua), U3.e(ub)), 1022), bit(lt)), W.h(g), W.l(g), rm)

def f64.div.go2(+sp: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32, +s: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.div.sp(ah, al, bh, bl, s)
    case False{}:
      f64.div.fin(ah, al, bh, bl, s, rm)

def f64.div(+ah: U32, +al: U32, +bh: U32, +bl: U32, +rm: U32) -> FR:
  +sp = Bool.or(Bool.or(U32.is_eq(f64.e(ah), 2047), U32.is_eq(f64.e(bh), 2047)), Bool.or(f64.iszero(ah, al), f64.iszero(bh, bl)))
  f64.div.go2(sp, ah, al, bh, bl, U32.shrn(U32.xor(ah, bh), 31n), rm)

# Square root
# -----------

def f64.sqrt.sp(+h: U32, +l: U32) -> FR:
  +ok = Bool.or(f64.iszero(h, l), Bool.and(U32.is_eq(h, 2146435072), isz(l)))
  FR{sel(ok, h, f64.nan()), sel(ok, l, 0), sel(Bool.or(f64.issnan(h, l), Bool.not(Bool.or(ok, f64.isnan(h, l)))), 16, 0)}

# Square root, digit by digit: n steps, each taking the next two bits of the
# radicand from the top of (xh, xl); (qh, ql) the root so far, (rh, rl) the
# remainder. Returns the root with bit 0 jammed by a nonzero remainder.
def f64.sqrt.loop(n: Nat, +xh: U32, +xl: U32, +qh: U32, +ql: U32, +rh: U32, +rl: U32) -> W:
  match n:
    case 0n:
      W{qh, U32.or(ql, bit(nz64(rh, rl)))}
    case 1n+p:
      +r4h = U32.or(U32.shln(rh, 2n), U32.shrn(rl, 30n))
      +r4l = U32.or(U32.shln(rl, 2n), U32.shrn(xh, 30n))
      +th = U32.or(U32.shln(qh, 2n), U32.shrn(ql, 30n))
      +tl = U32.or(U32.shln(ql, 2n), 1)
      +ge = Bool.not(lt64(r4h, r4l, th, tl))
      +d = sub64(r4h, r4l, th, tl)
      f64.sqrt.loop(p, U32.or(U32.shln(xh, 2n), U32.shrn(xl, 30n)), U32.shln(xl, 2n), U32.or(U32.shln(qh, 1n), U32.shrn(ql, 31n)), U32.or(U32.shln(ql, 1n), bit(ge)), sel(ge, W.h(d), r4h), sel(ge, W.l(d), r4l))

# The radicand m * 2^(56 or 57) gives a 55-bit root.
def f64.sqrt.fin(+h: U32, +l: U32, +rm: U32) -> FR:
  +u = f64.unpk(h, l)
  +e = U3.e(u)
  +x = shl64(U3.h(u), U3.l(u), sel(isz(U32.and(e, 1)), 11, 10))
  +q = f64.sqrt.loop(55n, W.h(x), W.l(x), 0, 0, 0, 0)
  +g = shl64(W.h(q), W.l(q), 8)
  f64.rp(0, U32.add(sra1(U32.sub(e, 1023)), 1022), W.h(g), W.l(g), rm)

def f64.sqrt.go(+sp: Bool, +h: U32, +l: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.sqrt.sp(h, l)
    case False{}:
      f64.sqrt.fin(h, l, rm)

def f64.sqrt(+h: U32, +l: U32, +rm: U32) -> FR:
  f64.sqrt.go(Bool.or(U32.is_ge(h, 2146435072), f64.iszero(h, l)), h, l, rm)

# Fused multiply-add (SoftFloat's mulAddF64, 64-bit-integer variant)
# ----------------------------------------------------------------

def f64.fma.sp(+ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32) -> FR:
  +ps = U32.shrn(U32.xor(ah, bh), 31n)
  +abnan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +abinf = Bool.and(Bool.not(abnan), Bool.or(f64.isinf(ah, al), f64.isinf(bh, bl)))
  +invp = Bool.and(abinf, Bool.or(f64.iszero(ah, al), f64.iszero(bh, bl)))
  +invs = Bool.and(Bool.and(abinf, Bool.not(invp)), Bool.and(f64.isinf(ch, cl), U32.is_ne(U32.shrn(ch, 31n), ps)))
  +inv = Bool.or(invp, invs)
  +nan = Bool.or(Bool.or(abnan, f64.isnan(ch, cl)), inv)
  +snan = Bool.or(Bool.or(f64.issnan(ah, al), f64.issnan(bh, bl)), f64.issnan(ch, cl))
  FR{sel(nan, f64.nan(), sel(abinf, f64.pk(ps, 2047, 0), ch)), sel(Bool.or(nan, abinf), 0, cl), sel(Bool.or(snan, inv), 16, 0)}

def f64.fma.zp(+ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32, +rm: U32) -> FR:
  +cancel = Bool.and(f64.iszero(ch, cl), U32.is_ne(U32.shrn(U32.xor(ah, bh), 31n), U32.shrn(ch, 31n)))
  FR{sel(cancel, U32.shln(bit(U32.is_eq(rm, 2)), 31n), ch), cl, 0}

def f64.fma.nrm2(+neg: Bool, +s: U32, +e: U32, +k: U32, +h: U32, +l: U32, +h0: U32, +l0: U32, +rm: U32) -> FR:
  match neg:
    case True{}:
      +v = srj64(h, l, 1)
      f64.rp(s, e, W.h(v), U32.or(W.l(v), bit(nz64(h0, l0))), rm)
    case False{}:
      +n = shl128(h, l, h0, l0, k)
      f64.rp(s, e, Q.a(n), U32.or(Q.b(n), bit(nz64(Q.c(n), Q.d(n)))), rm)

# normalizes a nonzero 128-bit significand p with exponent e, and rounds
def f64.fma.nrm(+s: U32, +e: U32, +p: Q, +rm: U32) -> FR:
  +up = Bool.not(nz64(Q.a(p), Q.b(p)))
  +h = sel(up, Q.c(p), Q.a(p))
  +l = sel(up, Q.d(p), Q.b(p))
  +k = U32.sub(clz64(h, l), 1)
  f64.fma.nrm2(isneg(k), s, U32.sub(sel(up, U32.sub(e, 64), e), k), k, h, l, sel(up, 0, Q.c(p)), sel(up, 0, Q.d(p)), rm)

def f64.fma.eq0(+z: Bool, +s: U32, +e: U32, +p: Q, +rm: U32) -> FR:
  match z:
    case True{}:
      FR{U32.shln(bit(U32.is_eq(rm, 2)), 31n), 0, 0}
    case False{}:
      +ng = isneg(Q.a(p))
      f64.fma.nrm(U32.xor(s, bit(ng)), e, qsel(ng, sub128(0, 0, 0, 0, Q.a(p), Q.b(p), Q.c(p), Q.d(p)), p), rm)

# the product aligned to c when its exponent is below c's, opposite signs:
# by one with full jamming, or else only its high half
def f64.fma.pj(+m1: Bool, +p: Q, +d: U32) -> Q:
  match m1:
    case True{}:
      srj128(Q.a(p), Q.b(p), Q.c(p), Q.d(p), 1)
    case False{}:
      +v = srj64(Q.a(p), Q.b(p), U32.sub(0, d))
      Q{W.h(v), W.l(v), Q.c(p), Q.d(p)}

# opposite signs; c3 is 0, 1, 2 as d = e - ec is below, at or above 0
def f64.fma.sub(+c3: U32, +s: U32, +sc: U32, +e: U32, +p: Q, +ec: U32, +gh: U32, +gl: U32, +d: U32, +rm: U32) -> FR:
  match c3:
    case 0:
      +q = f64.fma.pj(U32.is_eq(d, 4294967295), p, d)
      f64.fma.nrm(sc, ec, sub128(gh, gl, 0, 0, Q.a(q), Q.b(q), Q.c(q), Q.d(q)), rm)
    case 1:
      +v = sub64(Q.a(p), Q.b(p), gh, gl)
      f64.fma.eq0(Bool.not(Bool.or(nz64(W.h(v), W.l(v)), nz64(Q.c(p), Q.d(p)))), s, e, Q{W.h(v), W.l(v), Q.c(p), Q.d(p)}, rm)
    case _:
      +cc = srj128(gh, gl, 0, 0, d)
      f64.fma.nrm(s, e, sub128(Q.a(p), Q.b(p), Q.c(p), Q.d(p), Q.a(cc), Q.b(cc), Q.c(cc), Q.d(cc)), rm)

# equal signs
def f64.fma.add(+c3: U32, +s: U32, +e: U32, +p: Q, +ec: U32, +gh: U32, +gl: U32, +d: U32, +rm: U32) -> FR:
  match c3:
    case 0:
      +v = srj64(Q.a(p), Q.b(p), U32.sub(0, d))
      +z = add64(gh, gl, W.h(v), W.l(v))
      f64.nrp(s, ec, W.h(z), U32.or(W.l(z), bit(nz64(Q.c(p), Q.d(p)))), rm)
    case 1:
      +z = add64(gh, gl, Q.a(p), Q.b(p))
      f64.nrp(s, e, W.h(z), U32.or(W.l(z), bit(nz64(Q.c(p), Q.d(p)))), rm)
    case _:
      +cc = srj128(gh, gl, 0, 0, d)
      +z = add128(Q.a(p), Q.b(p), Q.c(p), Q.d(p), Q.a(cc), Q.b(cc), Q.c(cc), Q.d(cc))
      f64.nrp(s, e, Q.a(z), U32.or(Q.b(z), bit(nz64(Q.c(z), Q.d(z)))), rm)

def f64.fma.c2(+same: Bool, +c3: U32, +s: U32, +sc: U32, +e: U32, +p: Q, +ec: U32, +gh: U32, +gl: U32, +d: U32, +rm: U32) -> FR:
  match same:
    case True{}:
      f64.fma.add(c3, s, e, p, ec, gh, gl, d, rm)
    case False{}:
      f64.fma.sub(c3, s, sc, e, p, ec, gh, gl, d, rm)

# the product p has its leading 1 at bit 125 and exponent e
def f64.fma.c(+cz: Bool, +s: U32, +e: U32, +p: Q, +ch: U32, +cl: U32, +rm: U32) -> FR:
  match cz:
    case True{}:
      +g = shl64(Q.a(p), Q.b(p), 1)
      f64.rp(s, U32.sub(e, 1), W.h(g), U32.or(W.l(g), bit(nz64(Q.c(p), Q.d(p)))), rm)
    case False{}:
      +uc = f64.unpk(ch, cl)
      +gc = f64.g9(uc)
      +d = U32.sub(e, U3.e(uc))
      +sc = U32.shrn(ch, 31n)
      f64.fma.c2(U32.is_eq(s, sc), sel(isneg(d), 0, sel(isz(d), 1, 2)), s, sc, e, p, U3.e(uc), W.h(gc), W.l(gc), d, rm)

def f64.fma.fin(+ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32, +rm: U32) -> FR:
  +ua = f64.unpk(ah, al)
  +ub = f64.unpk(bh, bl)
  +x = f64.g10(ua)
  +y = f64.g10(ub)
  +p = mul64(W.h(x), W.l(x), W.h(y), W.l(y))
  +lo = U32.is_lt(Q.a(p), 536870912)
  +e = U32.sub(U32.sub(U32.add(U3.e(ua), U3.e(ub)), 1022), bit(lo))
  f64.fma.c(f64.iszero(ch, cl), U32.shrn(U32.xor(ah, bh), 31n), e, shl128(Q.a(p), Q.b(p), Q.c(p), Q.d(p), bit(lo)), ch, cl, rm)

def f64.fma.z(+z: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32, +rm: U32) -> FR:
  match z:
    case True{}:
      f64.fma.zp(ah, al, bh, bl, ch, cl, rm)
    case False{}:
      f64.fma.fin(ah, al, bh, bl, ch, cl, rm)

def f64.fma.go(+sp: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.fma.sp(ah, al, bh, bl, ch, cl)
    case False{}:
      f64.fma.z(Bool.or(f64.iszero(ah, al), f64.iszero(bh, bl)), ah, al, bh, bl, ch, cl, rm)

def f64.fma(+ah: U32, +al: U32, +bh: U32, +bl: U32, +ch: U32, +cl: U32, +rm: U32) -> FR:
  +sp = Bool.or(Bool.or(U32.is_eq(f64.e(ah), 2047), U32.is_eq(f64.e(bh), 2047)), U32.is_eq(f64.e(ch), 2047))
  f64.fma.go(sp, ah, al, bh, bl, ch, cl, rm)

# Compare, min, max, class
# ------------------------

def f64.same(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.and(U32.is_eq(ah, bh), U32.is_eq(al, bl))

# both zero, of either sign
def f64.zz(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.not(nz64(U32.shln(U32.or(ah, bh), 1n), U32.or(al, bl)))

def f64.eq(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> FR:
  +nan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +eq = Bool.or(f64.same(ah, al, bh, bl), f64.zz(ah, al, bh, bl))
  FR{0, bit(Bool.and(Bool.not(nan), eq)), sel(Bool.or(f64.issnan(ah, al), f64.issnan(bh, bl)), 16, 0)}

def f64.lt(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> FR:
  +nan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +sa = isneg(ah)
  +lt = bsel(Bool.xor(sa, isneg(bh)), Bool.and(sa, Bool.not(f64.zz(ah, al, bh, bl))), Bool.and(Bool.not(f64.same(ah, al, bh, bl)), Bool.xor(sa, lt64(ah, al, bh, bl))))
  FR{0, bit(Bool.and(Bool.not(nan), lt)), sel(nan, 16, 0)}

def f64.le(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> FR:
  +nan = Bool.or(f64.isnan(ah, al), f64.isnan(bh, bl))
  +sa = isneg(ah)
  +le = bsel(Bool.xor(sa, isneg(bh)), Bool.or(sa, f64.zz(ah, al, bh, bl)), Bool.or(f64.same(ah, al, bh, bl), Bool.xor(sa, lt64(ah, al, bh, bl))))
  FR{0, bit(Bool.and(Bool.not(nan), le)), sel(nan, 16, 0)}

# a < b for non-NaN values, with -0 < +0
def f64.lt.tot(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  +sa = isneg(ah)
  bsel(Bool.xor(sa, isneg(bh)), sa, Bool.and(Bool.not(f64.same(ah, al, bh, bl)), Bool.xor(sa, lt64(ah, al, bh, bl))))

def f64.mm(+ah: U32, +al: U32, +bh: U32, +bl: U32, +pa: Bool) -> FR:
  +an = f64.isnan(ah, al)
  +bn = f64.isnan(bh, bl)
  +both = Bool.and(an, bn)
  +ta = Bool.and(Bool.not(an), Bool.or(bn, pa))
  FR{sel(both, f64.nan(), sel(ta, ah, bh)), sel(both, 0, sel(ta, al, bl)), sel(Bool.or(f64.issnan(ah, al), f64.issnan(bh, bl)), 16, 0)}

def f64.min(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> FR:
  f64.mm(ah, al, bh, bl, f64.lt.tot(ah, al, bh, bl))

def f64.max(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> FR:
  f64.mm(ah, al, bh, bl, f64.lt.tot(bh, bl, ah, al))

def f64.class(+h: U32, +l: U32) -> FR:
  +e = f64.e(h)
  +fz = Bool.not(nz64(f64.mh(h), l))
  +s = isneg(h)
  +i = sel(U32.is_eq(e, 2047), sel(fz, sel(s, 0, 7), sel(nz(U32.and(h, 524288)), 9, 8)), sel(isz(e), sel(fz, sel(s, 3, 4), sel(s, 2, 5)), sel(s, 1, 6)))
  FR{0, U32.shln(1, U32.to_nat(i)), 0}

# Conversions
# -----------

# |x| = m * 2^(e - 1075): m << 11 shifted right by 1086 - e
def f64.toint(+h: U32, +l: U32, +rm: U32) -> CV:
  +e = f64.e(h)
  +mh = U32.or(f64.mh(h), sel(nz(e), 1048576, 0))
  +s = bit(Bool.and(isneg(h), Bool.not(f64.isnan(h, l))))
  cvt.rnd(s, U32.is_gt(e, 1086), srx(U32.or(U32.shln(mh, 11n), U32.shrn(l, 21n)), U32.shln(l, 11n), U32.sub(1086, e)), rm)

def f64.to_i32(+h: U32, +l: U32, +rm: U32) -> FR:
  cvt.i32(f64.toint(h, l, rm))

def f64.to_u32(+h: U32, +l: U32, +rm: U32) -> FR:
  cvt.u32(f64.toint(h, l, rm))

def f64.to_i64(+h: U32, +l: U32, +rm: U32) -> FR:
  cvt.i64(f64.toint(h, l, rm))

def f64.to_u64(+h: U32, +l: U32, +rm: U32) -> FR:
  cvt.u64(f64.toint(h, l, rm))

# sign s and magnitude (h, l), rounded
def f64.ofm(+s: U32, +h: U32, +l: U32, +rm: U32) -> FR:
  +k = clz64(h, l)
  +n = shl64(h, l, k)
  +g = srj64(W.h(n), W.l(n), 1)
  f64.rp(s, U32.sub(1085, k), W.h(g), W.l(g), rm)

def f64.of_u64(+h: U32, +l: U32, +rm: U32) -> FR:
  f64.ofm(0, h, l, rm)

def f64.of_i64(+h: U32, +l: U32, +rm: U32) -> FR:
  +s = isneg(h)
  +n = sub64(0, 0, h, l)
  f64.ofm(bit(s), sel(s, W.h(n), h), sel(s, W.l(n), l), rm)

def f64.of_u32(+v: U32, +rm: U32) -> FR:
  f64.ofm(0, 0, v, rm)

def f64.of_i32(+v: U32, +rm: U32) -> FR:
  +s = isneg(v)
  f64.ofm(bit(s), 0, sel(s, U32.sub(0, v), v), rm)

def f64.to_f32.sp(+h: U32, +l: U32) -> FR:
  FR{0, sel(f64.isnan(h, l), f32.nan(), U32.or(U32.and(h, 2147483648), 2139095040)), sel(f64.issnan(h, l), 16, 0)}

def f64.to_f32.go(+sp: Bool, +h: U32, +l: U32, +rm: U32) -> FR:
  match sp:
    case True{}:
      f64.to_f32.sp(h, l)
    case False{}:
      f64.to_f32.fin(h, l, rm)

def f64.to_f32(+h: U32, +l: U32, +rm: U32) -> FR:
  f64.to_f32.go(U32.is_eq(f64.e(h), 2047), h, l, rm)
