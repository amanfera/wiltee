import Base
import ./rvc.bend as RVC

# One RV64 hart (IMA + C, Zicsr, Zifencei; S and U modes; Sv39) as a total,
# pure state transformer, built from U32 pairs because Bend has no 64-bit
# integers. As in hart.bend, wiltee plays the M-mode firmware itself: every
# trap lands in S-mode and an S-mode ECALL is answered here as an SBI call.
#
# A 64-bit value is (h, l): register r lives at x[2r] (low) and x[2r+1]
# (high); the FP registers follow at x[64 + 2r], and fcsr at x[128].
#
# Nothing in this file is @unsafe: `run` and `epoch` count down a Nat.

# Words
# -----

def sel(+c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

def bit(+c: Bool) -> U32:
  sel(c, 1, 0)

def nz(+a: U32) -> Bool:
  U32.is_ne(a, 0)

def isneg(+a: U32) -> Bool:
  U32.is_ge(a, 2147483648)

# The high word of a sign-extended 32-bit value.
def sx(+a: U32) -> U32:
  sel(isneg(a), 4294967295, 0)

def slt(+a: U32, +b: U32) -> Bool:
  U32.is_lt(U32.xor(a, 2147483648), U32.xor(b, 2147483648))

def neg(+a: U32) -> U32:
  U32.sub(0, a)

def shamt(+a: U32) -> Nat:
  U32.to_nat(U32.and(a, 31))

def sra(+a: U32, +s: Nat) -> U32:
  sel(isneg(a), U32.not(U32.shrn(U32.not(a), s)), U32.shrn(a, s))

def sext8(+a: U32) -> U32:
  U32.sub(U32.xor(U32.and(a, 255), 128), 128)

def sext16(+a: U32) -> U32:
  U32.sub(U32.xor(U32.and(a, 65535), 32768), 32768)

def umin(+a: U32, +b: U32) -> U32:
  sel(U32.is_lt(a, b), a, b)

# a >= b on 64-bit values given as (hi, lo)
def ge64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.or(U32.is_gt(ah, bh), Bool.and(U32.is_eq(ah, bh), U32.is_ge(al, bl)))

# high word of the 32x32 product, from 16-bit limbs
def mulhu(+a: U32, +b: U32) -> U32:
  +a0 = U32.and(a, 65535)
  +a1 = U32.shrn(a, 16n)
  +b0 = U32.and(b, 65535)
  +b1 = U32.shrn(b, 16n)
  +lh = U32.mul(a0, b1)
  +hl = U32.mul(a1, b0)
  +mid = U32.add(U32.add(U32.shrn(U32.mul(a0, b0), 16n), U32.and(lh, 65535)), U32.and(hl, 65535))
  U32.add(U32.add(U32.mul(a1, b1), U32.add(U32.shrn(lh, 16n), U32.shrn(hl, 16n))), U32.shrn(mid, 16n))

def uabs(+a: U32) -> U32:
  sel(isneg(a), neg(a), a)

# 32-bit division, for the *W ops (RISC-V results for /0 and overflow)
def divu.go(+z: Bool, +a: U32, +b: U32) -> U32:
  match z:
    case True{}:
      4294967295
    case False{}:
      U32.div(a, b)

def divu(+a: U32, +b: U32) -> U32:
  divu.go(U32.is_zero(b), a, b)

def remu.go(+z: Bool, +a: U32, +b: U32) -> U32:
  match z:
    case True{}:
      a
    case False{}:
      U32.mod(a, b)

def remu(+a: U32, +b: U32) -> U32:
  remu.go(U32.is_zero(b), a, b)

def div.go(+z: Bool, +o: Bool, +a: U32, +b: U32) -> U32:
  match z o:
    case True{} _:
      4294967295
    case False{} True{}:
      a
    case False{} False{}:
      +q = U32.div(uabs(a), uabs(b))
      sel(Bool.xor(isneg(a), isneg(b)), neg(q), q)

def div(+a: U32, +b: U32) -> U32:
  div.go(U32.is_zero(b), Bool.and(U32.is_eq(a, 2147483648), U32.is_eq(b, 4294967295)), a, b)

def rem.go(+z: Bool, +o: Bool, +a: U32, +b: U32) -> U32:
  match z o:
    case True{} _:
      a
    case False{} True{}:
      0
    case False{} False{}:
      +r = U32.mod(uabs(a), uabs(b))
      sel(isneg(a), neg(r), r)

def rem(+a: U32, +b: U32) -> U32:
  rem.go(U32.is_zero(b), Bool.and(U32.is_eq(a, 2147483648), U32.is_eq(b, 4294967295)), a, b)

# 64-bit arithmetic on (hi, lo) pairs
# ---------------------------------

type W is Data:
  W{h: U32, l: U32}

def add64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  +l = U32.add(al, bl)
  W{U32.add(U32.add(ah, bh), bit(U32.is_lt(l, al))), l}

def sub64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  W{U32.sub(U32.sub(ah, bh), bit(U32.is_lt(al, bl))), U32.sub(al, bl)}

def eq64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.and(U32.is_eq(ah, bh), U32.is_eq(al, bl))

def ltu64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.or(U32.is_lt(ah, bh), Bool.and(U32.is_eq(ah, bh), U32.is_lt(al, bl)))

def lt64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.or(slt(ah, bh), Bool.and(U32.is_eq(ah, bh), U32.is_lt(al, bl)))

# Shifts by s in 0..63 (callers mask). Shifts by 32 or more are split off
# so that no U32 shift amount reaches 32.
def sll64.lo(+z: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match z:
    case True{}:
      W{h, l}
    case False{}:
      W{U32.or(U32.shln(h, U32.to_nat(s)), U32.shrn(l, U32.to_nat(U32.sub(32, s)))), U32.shln(l, U32.to_nat(s))}

def sll64.k(+big: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match big:
    case True{}:
      W{U32.shln(l, U32.to_nat(U32.and(s, 31))), 0}
    case False{}:
      sll64.lo(U32.is_zero(s), h, l, s)

def sll64(+h: U32, +l: U32, +s: U32) -> W:
  sll64.k(U32.is_ge(U32.and(s, 63), 32), h, l, U32.and(s, 63))

def srl64.lo(+z: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match z:
    case True{}:
      W{h, l}
    case False{}:
      W{U32.shrn(h, U32.to_nat(s)), U32.or(U32.shrn(l, U32.to_nat(s)), U32.shln(h, U32.to_nat(U32.sub(32, s))))}

def srl64.k(+big: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match big:
    case True{}:
      W{0, U32.shrn(h, U32.to_nat(U32.and(s, 31)))}
    case False{}:
      srl64.lo(U32.is_zero(s), h, l, s)

def srl64(+h: U32, +l: U32, +s: U32) -> W:
  srl64.k(U32.is_ge(U32.and(s, 63), 32), h, l, U32.and(s, 63))

def sra64.lo(+z: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match z:
    case True{}:
      W{h, l}
    case False{}:
      W{sra(h, U32.to_nat(s)), U32.or(U32.shrn(l, U32.to_nat(s)), U32.shln(h, U32.to_nat(U32.sub(32, s))))}

def sra64.k(+big: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match big:
    case True{}:
      W{sx(h), sra(h, U32.to_nat(U32.and(s, 31)))}
    case False{}:
      sra64.lo(U32.is_zero(s), h, l, s)

def sra64(+h: U32, +l: U32, +s: U32) -> W:
  sra64.k(U32.is_ge(U32.and(s, 63), 32), h, l, U32.and(s, 63))

# SRLI/SRAI/SRL/SRA: arithmetic when `ar`.
def sr64(+ar: Bool, +h: U32, +l: U32, +s: U32) -> W:
  match ar:
    case True{}:
      sra64(h, l, s)
    case False{}:
      srl64(h, l, s)

def mul64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  W{U32.add(U32.add(mulhu(al, bl), U32.mul(al, bh)), U32.mul(ah, bl)), U32.mul(al, bl)}

def mulhu64.c(+p11h: U32, +p11l: U32, +p01h: U32, +p10h: U32, +c: U32) -> W:
  +l1 = U32.add(p11l, p01h)
  +l2 = U32.add(l1, p10h)
  +l3 = U32.add(l2, c)
  W{U32.add(U32.add(p11h, bit(U32.is_lt(l1, p11l))), U32.add(bit(U32.is_lt(l2, l1)), bit(U32.is_lt(l3, l2)))), l3}

# High 64 bits of the 128-bit product: p11<<64 + (p01 + p10 + p00.hi)<<32.
def mulhu64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  +p01l = U32.mul(al, bh)
  +p10l = U32.mul(ah, bl)
  +t1 = U32.add(p01l, p10l)
  +t2 = U32.add(t1, mulhu(al, bl))
  mulhu64.c(mulhu(ah, bh), U32.mul(ah, bh), mulhu(al, bh), mulhu(ah, bl), U32.add(bit(U32.is_lt(t1, p01l)), bit(U32.is_lt(t2, t1))))

def mulhsu64.k(+ah: U32, +bh: U32, +bl: U32, r: W) -> W:
  W{h, l} = r
  sub64(h, l, sel(isneg(ah), bh, 0), sel(isneg(ah), bl, 0))

def mulhsu64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  mulhsu64.k(ah, bh, bl, mulhu64(ah, al, bh, bl))

def mulh64.k(+bh: U32, +ah: U32, +al: U32, r: W) -> W:
  W{h, l} = r
  sub64(h, l, sel(isneg(bh), ah, 0), sel(isneg(bh), al, 0))

def mulh64(+ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  mulh64.k(bh, ah, al, mulhsu64(ah, al, bh, bl))

type QR is Data:
  QR{qh: U32, ql: U32, rh: U32, rl: U32}

# Restoring division, one quotient bit per step: (qh, ql) shifts the
# dividend out at the top and takes the quotient in at the bottom; (rh, rl)
# is the remainder. A remainder with its top bit set exceeds any divisor
# once shifted, so it subtracts unconditionally.
def udiv.go(k: Nat, +dh: U32, +dl: U32, +qh: U32, +ql: U32, +rh: U32, +rl: U32) -> QR:
  match k:
    case 0n:
      QR{qh, ql, rh, rl}
    case 1n+p:
      +r2h = U32.or(U32.shln(rh, 1n), U32.shrn(rl, 31n))
      +r2l = U32.or(U32.shln(rl, 1n), U32.shrn(qh, 31n))
      +ge = Bool.or(isneg(rh), ge64(r2h, r2l, dh, dl))
      udiv.go(p, dh, dl, U32.or(U32.shln(qh, 1n), U32.shrn(ql, 31n)), U32.or(U32.shln(ql, 1n), bit(ge)), sel(ge, U32.sub(U32.sub(r2h, dh), bit(U32.is_lt(r2l, dl))), r2h), sel(ge, U32.sub(r2l, dl), r2l))

# 64 / 16-bit divisor: four 16-bit digits, each a native 32-bit division.
def udiv16(+nh: U32, +nl: U32, +d: U32) -> QR:
  +c0 = U32.shrn(nh, 16n)
  +c1 = U32.or(U32.shln(U32.mod(c0, d), 16n), U32.and(nh, 65535))
  +c2 = U32.or(U32.shln(U32.mod(c1, d), 16n), U32.shrn(nl, 16n))
  +c3 = U32.or(U32.shln(U32.mod(c2, d), 16n), U32.and(nl, 65535))
  QR{U32.or(U32.shln(U32.div(c0, d), 16n), U32.div(c1, d)), U32.or(U32.shln(U32.div(c2, d), 16n), U32.div(c3, d)), 0, U32.mod(c3, d)}

def udiv.k(+path: U32, +nh: U32, +nl: U32, +dh: U32, +dl: U32) -> QR:
  match path:
    case 0:
      QR{0, U32.div(nl, dl), 0, U32.mod(nl, dl)}
    case 1:
      udiv16(nh, nl, dl)
    case 2:
      udiv.go(32n, dh, dl, nl, 0, 0, 0)
    case _:
      udiv.go(64n, dh, dl, nh, nl, 0, 0)

# Unsigned 64-bit quotient and remainder; the divisor is not zero.
def udiv(+nh: U32, +nl: U32, +dh: U32, +dl: U32) -> QR:
  udiv.k(sel(U32.is_zero(U32.or(nh, dh)), 0, sel(Bool.and(U32.is_zero(dh), U32.is_lt(dl, 65536)), 1, sel(U32.is_zero(nh), 2, 3))), nh, nl, dh, dl)

def neg.if(+c: Bool, +h: U32, +l: U32) -> W:
  match c:
    case True{}:
      sub64(0, 0, h, l)
    case False{}:
      W{h, l}

def udiv.fin(+rm: Bool, r: QR) -> W:
  match rm:
    case True{}:
      QR{qh, ql, rh, rl} = r
      W{rh, rl}
    case False{}:
      QR{qh, ql, rh, rl} = r
      W{qh, ql}

def udiv64.k(+z: Bool, +rm: Bool, +nh: U32, +nl: U32, +dh: U32, +dl: U32) -> W:
  match z rm:
    case True{} True{}:
      W{nh, nl}
    case True{} False{}:
      W{4294967295, 4294967295}
    case False{} _:
      udiv.fin(rm, udiv(nh, nl, dh, dl))

# DIVU (rm = False) and REMU (rm = True).
def udiv64(+rm: Bool, +nh: U32, +nl: U32, +dh: U32, +dl: U32) -> W:
  udiv64.k(U32.is_zero(U32.or(dh, dl)), rm, nh, nl, dh, dl)

def sdiv.fin(+rm: Bool, +sq: Bool, +sr: Bool, r: QR) -> W:
  match rm:
    case True{}:
      QR{qh, ql, rh, rl} = r
      neg.if(sr, rh, rl)
    case False{}:
      QR{qh, ql, rh, rl} = r
      neg.if(sq, qh, ql)

def sdiv.go(+rm: Bool, +nh: U32, +dh: U32, a: W, b: W) -> W:
  W{ah, al} = a
  W{bh, bl} = b
  sdiv.fin(rm, Bool.xor(isneg(nh), isneg(dh)), isneg(nh), udiv(ah, al, bh, bl))

def sdiv.k(+z: Bool, +o: Bool, +rm: Bool, +nh: U32, +nl: U32, +dh: U32, +dl: U32) -> W:
  match z o rm:
    case True{} _ True{}:
      W{nh, nl}
    case True{} _ False{}:
      W{4294967295, 4294967295}
    case False{} True{} True{}:
      W{0, 0}
    case False{} True{} False{}:
      W{nh, nl}
    case False{} False{} _:
      sdiv.go(rm, nh, dh, neg.if(isneg(nh), nh, nl), neg.if(isneg(dh), dh, dl))

# DIV (rm = False) and REM (rm = True).
def sdiv64(+rm: Bool, +nh: U32, +nl: U32, +dh: U32, +dl: U32) -> W:
  sdiv.k(U32.is_zero(U32.or(dh, dl)), Bool.and(eq64(nh, nl, 2147483648, 0), eq64(dh, dl, 4294967295, 4294967295)), rm, nh, nl, dh, dl)

# Multi-reads: an array read hands the array back, so N reads fold into one
# record instead of N continuation defs at every call site.
# --------------------------------------------------------------------------

type R2 is Type:
  R2{a: Array<U32>, u: U32, v: U32}

type R3 is Type:
  R3{a: Array<U32>, u: U32, v: U32, w: U32}

type R4 is Type:
  R4{a: Array<U32>, u: U32, v: U32, w: U32, z: U32}

def get2.b(+u: U32, p: Array<U32> & U32) -> R2:
  (a, v) = p
  R2{a, u, v}

def get2.a(+j: U32, p: Array<U32> & U32) -> R2:
  (a, u) = p
  get2.b(u, Array.get(U32, a, j))

def get2(a: Array<U32>, +i: U32, +j: U32) -> R2:
  get2.a(j, Array.get(U32, a, i))

def get3.b(+u: U32, r: R2) -> R3:
  R2{a, v, w} = r
  R3{a, u, v, w}

def get3.a(+j: U32, +k: U32, p: Array<U32> & U32) -> R3:
  (a, u) = p
  get3.b(u, get2(a, j, k))

def get3(a: Array<U32>, +i: U32, +j: U32, +k: U32) -> R3:
  get3.a(j, k, Array.get(U32, a, i))

def get4.b(+u: U32, +v: U32, r: R2) -> R4:
  R2{a, w, z} = r
  R4{a, u, v, w, z}

def get4.a(+k: U32, +l: U32, r: R2) -> R4:
  R2{a, u, v} = r
  get4.b(u, v, get2(a, k, l))

def get4(a: Array<U32>, +i: U32, +j: U32, +k: U32, +l: U32) -> R4:
  get4.a(k, l, get2(a, i, j))

# State
# -----

# The S-mode CSRs. 64-bit ones are (h, l) pairs: stvec (tvh, tvl), sscratch
# (sch, scl), sepc (eph, epl), stval (tlh, tll), satp (sah, sal: MODE and
# PPN[43:32] in sah, ASID hardwired to 0). `cause` keeps the interrupt flag
# in bit 31. `ip` holds only SSIP; STIP and SEIP live in the device words.
type Csr is Data:
  Csr{priv: U32, st: U32, ie: U32, ip: U32, tvh: U32, tvl: U32, sch: U32, scl: U32, eph: U32, epl: U32, cause: U32, tlh: U32, tll: U32, sah: U32, sal: U32, cen: U32, env: U32}

# go: keep running (the slice loop ends a slice on False)
# ph, pl: the pc; n: low word of the instruction count, also `time`
# md: hot-path mode: bit0 S-mode, bit1 SUM, bit2 MXR, bit3 Sv39 on,
#     bit4 FP on (FS != 0), bit5 FP state dirty (FS = 3)
# fv, fp: fetch tag and physical page of the last fetch (fv = 1: none)
# x: registers, m: RAM, s: CSRs, d: device words, t: TLB
type Hart is Type:
  Hart{go: Bool, ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>}

# A translation: the arrays it may touch, and r = physical page, or 1 on a fault.
type Wk is Type:
  Wk{m: Array<U32>, s: Csr, t: Array<U32>, r: U32}

# RAM size in bytes, at physical 0; must match the array the host builds.
def RAM() -> U32:
  134217728

def X.FCSR() -> U32:
  128

# Device words (indices into d).
def D.NH() -> U32:
  0
def D.CL() -> U32:
  1
def D.CH() -> U32:
  2
def D.WFI() -> U32:
  3
def D.EXIT() -> U32:
  4
def D.RESV() -> U32:
  5
def D.HART() -> U32:
  6
def D.STIP() -> U32:
  7
def D.SEIP() -> U32:
  8
def D.LEFT() -> U32:
  9
def U.IER() -> U32:
  10
def U.LCR() -> U32:
  11
def U.MCR() -> U32:
  12
def U.DLL() -> U32:
  13
def U.DLM() -> U32:
  14
def U.THRE() -> U32:
  15
def U.RXH() -> U32:
  16
def U.RXT() -> U32:
  17
def U.TXN() -> U32:
  18
def D.TRACE() -> U32:
  19
def P.IP() -> U32:
  20
def P.MASK() -> U32:
  21
def P.IE() -> U32:
  22
def P.TH() -> U32:
  23
# RX ring: 256 bytes at 256. TX buffer: 65536 bytes at 65536, drained by the
# host after every epoch.
def U.RX() -> U32:
  256
def U.TX() -> U32:
  65536

def md.of(+priv: U32, +st: U32, +sah: U32) -> U32:
  +fs = U32.and(U32.shrn(st, 13n), 3)
  U32.or(U32.or(U32.or(priv, U32.and(U32.shrn(st, 17n), 6)), U32.shln(bit(U32.is_eq(U32.shrn(sah, 28n), 8)), 3n)), U32.or(U32.shln(bit(nz(fs)), 4n), U32.shln(bit(U32.is_eq(fs, 3)), 5n)))

# Instruction fields
# ------------------

def F.rd(+i: U32) -> U32:
  U32.and(U32.shrn(i, 7n), 31)

def F.rs1(+i: U32) -> U32:
  U32.and(U32.shrn(i, 15n), 31)

def F.rs2(+i: U32) -> U32:
  U32.and(U32.shrn(i, 20n), 31)

def F.f3(+i: U32) -> U32:
  U32.and(U32.shrn(i, 12n), 7)

# Immediates as sign-extended 32-bit words (sx gives the high word).
def F.immI(+i: U32) -> U32:
  sra(i, 20n)

def F.immS(+i: U32) -> U32:
  U32.or(U32.shln(sra(i, 25n), 5n), U32.and(U32.shrn(i, 7n), 31))

def F.immB(+i: U32) -> U32:
  U32.or(U32.or(U32.shln(sra(i, 31n), 12n), U32.and(U32.shln(i, 4n), 2048)), U32.or(U32.and(U32.shrn(i, 20n), 2016), U32.and(U32.shrn(i, 7n), 30)))

def F.immJ(+i: U32) -> U32:
  U32.or(U32.or(U32.shln(sra(i, 31n), 20n), U32.and(i, 1044480)), U32.or(U32.and(U32.shrn(i, 9n), 2048), U32.and(U32.shrn(i, 20n), 2046)))

# Control
# -------
# Handlers take (ph, pl) = pc and il = the instruction's length (2 or 4).

# Enters the S-mode trap handler (vectored for interrupts when stvec.MODE = 1).
def trap(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +cause: U32, +vh: U32, +vl: U32) -> Hart:
  Csr{+pr, +st, ie, ip, +tvh, +tvl, sch, scl, eph, epl, ca, tlh, tll, +sah, sal, cen, env} = s
  +st2 = U32.or(U32.and(st, 4294967005), U32.or(U32.shln(pr, 8n), U32.shln(U32.and(st, 2), 4n)))
  +base = U32.and(tvl, 4294967292)
  +vec = sel(Bool.and(isneg(cause), U32.is_eq(U32.and(tvl, 3), 1)), U32.add(base, U32.shln(U32.and(cause, 31), 2n)), base)
  Hart{True{}, tvh, vec, n, md.of(1, st2, sah), 1, fp, x, m, Csr{1, st2, ie, ip, tvh, tvl, sch, scl, ph, pl, cause, vh, vl, sah, sal, cen, env}, d, t}

def illegal(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 2, 0, inst)

# Writes rd (x0 stays 0) and moves to the next instruction.
def wr(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +vh: U32, +vl: U32) -> Hart:
  +i = U32.shln(rd, 1n)
  x[i] <- vl
  x[U32.add(i, 1)] <- vh
  x[0] <- 0
  x[1] <- 0
  +npl = U32.add(pl, il)
  Hart{True{}, U32.add(ph, bit(U32.is_lt(npl, il))), npl, n, md, fv, fp, x, m, s, d, t}

# The same, but ends the slice, so the slice loop re-reads interrupts.
def wr.stop(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +vh: U32, +vl: U32) -> Hart:
  +i = U32.shln(rd, 1n)
  x[i] <- vl
  x[U32.add(i, 1)] <- vh
  x[0] <- 0
  x[1] <- 0
  +npl = U32.add(pl, il)
  Hart{False{}, U32.add(ph, bit(U32.is_lt(npl, il))), npl, n, md, fv, fp, x, m, s, d, t}

def wr.w(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, w: W) -> Hart:
  W{h, l} = w
  wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, h, l)

# A 32-bit result, sign-extended (the *W ops).
def wr32(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +v: U32) -> Hart:
  wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sx(v), v)

def nxt(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  +npl = U32.add(pl, il)
  Hart{True{}, U32.add(ph, bit(U32.is_lt(npl, il))), npl, n, md, fv, fp, x, m, s, d, t}

def nxt.stop(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  +npl = U32.add(pl, il)
  Hart{False{}, U32.add(ph, bit(U32.is_lt(npl, il))), npl, n, md, fv, fp, x, m, s, d, t}

# A jump with no link. Leaving the pc's 4 GiB window drops the fetch tag,
# whose high part only keeps bits 38..32.
def go.to(+ph: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +th: U32, +tl: U32) -> Hart:
  Hart{True{}, th, tl, n, md, sel(U32.is_eq(th, ph), fv, 1), fp, x, m, s, d, t}

# Jumps to (th, tl), linking into rd. With C, targets only need 2-byte
# alignment, which every jump guarantees, so jumps never trap.
def jmp(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +th: U32, +tl: U32) -> Hart:
  +npl = U32.add(pl, il)
  +i = U32.shln(rd, 1n)
  x[i] <- npl
  x[U32.add(i, 1)] <- U32.add(ph, bit(U32.is_lt(npl, il)))
  x[0] <- 0
  x[1] <- 0
  Hart{True{}, th, tl, n, md, sel(U32.is_eq(th, ph), fv, 1), fp, x, m, s, d, t}

# MMU (Sv39)
# ----------

def tlb.clr(k: Nat, t: Array<U32>, +i: U32) -> Array<U32>:
  match k:
    case 0n:
      t
    case 1n+p:
      t[i] <- 0
      tlb.clr(p, t, U32.add(i, 2))

def tlb.flush(t: Array<U32>) -> Array<U32>:
  tlb.clr(256n, t, 0)

# The tag of a virtual page: VA[31:12], VA[38:32] in bits 7..1, valid bit 0.
# Only canonical addresses (bits 63..39 equal to bit 38) get this far.
def tag.of(+vh: U32, +vl: U32) -> U32:
  U32.or(U32.or(U32.and(vl, 4294963200), U32.shln(U32.and(vh, 127), 1n)), 1)

# f: PTE flags; kind 0 load, 1 store, 2 fetch; md as in Hart.
def perm(+f: U32, +kind: U32, +md: U32) -> Bool:
  +u = nz(U32.and(f, 16))
  +pv = sel(nz(U32.and(md, 1)), bit(Bool.or(Bool.not(u), Bool.and(U32.is_ne(kind, 2), nz(U32.and(md, 2))))), bit(u))
  +rx = Bool.or(nz(U32.and(f, 2)), Bool.and(nz(U32.and(md, 4)), nz(U32.and(f, 8))))
  +ok = sel(U32.is_eq(kind, 0), bit(rx), sel(U32.is_eq(kind, 1), bit(nz(U32.and(f, 4))), bit(nz(U32.and(f, 8)))))
  nz(U32.and(pv, ok))

# 0: invalid, 1: leaf, 2: pointer to the next level (inside RAM). A PTE
# whose physical page lies at or above 4 GiB, or with reserved bits set,
# is invalid here: wiltee's physical address space is below 4 GiB.
def pte.cls(+lo: U32, +hi: U32) -> U32:
  +bad = Bool.or(Bool.or(nz(hi), nz(U32.shrn(lo, 30n))), Bool.or(U32.is_zero(U32.and(lo, 1)), U32.is_eq(U32.and(lo, 6), 4)))
  +leaf = nz(U32.and(lo, 10))
  sel(bad, 0, sel(leaf, 1, sel(U32.is_lt(U32.shln(U32.shrn(lo, 10n), 12n), RAM()), 2, 0)))

# The 4 KiB physical page of va inside a leaf at level lv (0: 4K, 1: 2M,
# 2: 1G), or 1 when a superpage is misaligned.
def leaf.pg(+lv: U32, +lo: U32, +vl: U32) -> U32:
  match lv:
    case 0:
      U32.shln(U32.shrn(lo, 10n), 12n)
    case 1:
      sel(nz(U32.and(U32.shrn(lo, 10n), 511)), 1, U32.or(U32.shln(U32.shrn(lo, 19n), 21n), U32.and(vl, 2093056)))
    case _:
      sel(nz(U32.and(U32.shrn(lo, 10n), 262143)), 1, U32.or(U32.shln(U32.shrn(lo, 28n), 30n), U32.and(vl, 1073737728)))

# A leaf passed its checks: set A (and D on a store), fill the TLB.
def walk.fill(+ok: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +kind: U32, +vh: U32, +vl: U32, +a: U32, +pte: U32, +pg: U32) -> Wk:
  match ok:
    case False{}:
      Wk{m, s, t, 1}
    case True{}:
      +np = U32.or(pte, sel(U32.is_eq(kind, 1), 192, 64))
      m[U32.shrn(a, 2n)] <- np
      +i = U32.shln(U32.and(U32.shrn(vl, 12n), 255), 1n)
      t[i] <- tag.of(vh, vl)
      t[U32.add(i, 1)] <- U32.or(pg, U32.and(np, 255))
      Wk{m, s, t, pg}

def walk.leaf(+pg: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, +pte: U32) -> Wk:
  walk.fill(Bool.and(U32.is_ne(pg, 1), perm(pte, kind, md)), m, s, t, kind, vh, vl, a, pte, pg)

def walk.l0k(+c: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, +lo: U32) -> Wk:
  match c:
    case 1:
      walk.leaf(leaf.pg(0, lo, vl), m, s, t, md, kind, vh, vl, a, lo)
    case _:
      Wk{m, s, t, 1}

def walk.l0(s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, r: R2) -> Wk:
  R2{m, +lo, +hi} = r
  walk.l0k(pte.cls(lo, hi), m, s, t, md, kind, vh, vl, a, lo)

def walk.l1k(+c: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, +lo: U32) -> Wk:
  match c:
    case 1:
      walk.leaf(leaf.pg(1, lo, vl), m, s, t, md, kind, vh, vl, a, lo)
    case 2:
      +a0 = U32.add(U32.shln(U32.shrn(lo, 10n), 12n), U32.shln(U32.and(U32.shrn(vl, 12n), 511), 3n))
      walk.l0(s, t, md, kind, vh, vl, a0, get2(m, U32.shrn(a0, 2n), U32.add(U32.shrn(a0, 2n), 1)))
    case _:
      Wk{m, s, t, 1}

def walk.l1(s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, r: R2) -> Wk:
  R2{m, +lo, +hi} = r
  walk.l1k(pte.cls(lo, hi), m, s, t, md, kind, vh, vl, a, lo)

def walk.l2k(+c: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, +lo: U32) -> Wk:
  match c:
    case 1:
      walk.leaf(leaf.pg(2, lo, vl), m, s, t, md, kind, vh, vl, a, lo)
    case 2:
      +a1 = U32.add(U32.shln(U32.shrn(lo, 10n), 12n), U32.shln(U32.and(U32.shrn(vl, 21n), 511), 3n))
      walk.l1(s, t, md, kind, vh, vl, a1, get2(m, U32.shrn(a1, 2n), U32.add(U32.shrn(a1, 2n), 1)))
    case _:
      Wk{m, s, t, 1}

def walk.l2(s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32, r: R2) -> Wk:
  R2{m, +lo, +hi} = r
  walk.l2k(pte.cls(lo, hi), m, s, t, md, kind, vh, vl, a, lo)

def walk.root(+ok: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +a: U32) -> Wk:
  match ok:
    case True{}:
      walk.l2(s, t, md, kind, vh, vl, a, get2(m, U32.shrn(a, 2n), U32.add(U32.shrn(a, 2n), 1)))
    case False{}:
      Wk{m, s, t, 1}

# The Sv39 page walk: VPN[2] = VA[38:30], VPN[1] = VA[29:21], VPN[0] = VA[20:12].
def walk(m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32) -> Wk:
  Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, +sah, +sal, cen, env} = s
  +root = U32.shln(sal, 12n)
  +a = U32.add(root, U32.shln(U32.or(U32.shln(U32.and(vh, 127), 2n), U32.shrn(vl, 30n)), 3n))
  walk.root(Bool.and(Bool.and(U32.is_lt(sal, 1048576), U32.is_zero(U32.and(sah, 4095))), U32.is_lt(root, RAM())), m, Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, t, md, kind, vh, vl, a)

def xl.h(+hit: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32, +dat: U32) -> Wk:
  match hit:
    case True{}:
      Wk{m, s, t, U32.and(dat, 4294963200)}
    case False{}:
      walk(m, s, t, md, kind, vh, vl)

def xl.t(m: Array<U32>, s: Csr, r: R2, +md: U32, +kind: U32, +vh: U32, +vl: U32) -> Wk:
  R2{t, tag, +dat} = r
  +ok = Bool.and(perm(dat, kind, md), Bool.or(U32.is_ne(kind, 1), nz(U32.and(dat, 128))))
  xl.h(Bool.and(U32.is_eq(tag, tag.of(vh, vl)), ok), m, s, t, md, kind, vh, vl, dat)

def xl.c(+canon: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32) -> Wk:
  match canon:
    case True{}:
      +i = U32.shln(U32.and(U32.shrn(vl, 12n), 255), 1n)
      xl.t(m, s, get2(t, i, U32.add(i, 1)), md, kind, vh, vl)
    case False{}:
      Wk{m, s, t, 1}

def xl.b(+on: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32) -> Wk:
  match on:
    case False{}:
      Wk{m, s, t, sel(U32.is_zero(vh), U32.and(vl, 4294963200), 1)}
    case True{}:
      xl.c(U32.is_zero(U32.shrn(U32.add(vh, 64), 7n)), m, s, t, md, kind, vh, vl)

# Translates va = (vh, vl) for an access of `kind`; the TLB first, then the
# walk. With the MMU off, physical addresses above 4 GiB fault.
def xl(m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +vh: U32, +vl: U32) -> Wk:
  xl.b(nz(U32.and(md, 8)), m, s, t, md, kind, vh, vl)

# Devices: a 16550 UART and a PLIC, both local to the hart's lane
# ---------------------------------------------------------------

def dev.upd.c(+ip: U32, p: Array<U32> & U32) -> Array<U32>:
  (d, ie) = p
  d[D.SEIP()] <- bit(nz(U32.and(ip, ie)))
  d

# Level-triggered gateway as in semu: a claimed source stays masked until it
# completes; while masked its line cannot re-pend.
def dev.upd.b(+ier: U32, +rxp: Bool, r: R3) -> Array<U32>:
  R3{d, thre, +ip, +mask} = r
  +act = U32.shln(bit(Bool.or(rxp, Bool.and(nz(U32.and(ier, 2)), nz(thre)))), 1n)
  +ip2 = U32.or(ip, U32.and(act, U32.not(mask)))
  d[P.IP()] <- ip2
  d[P.MASK()] <- U32.or(mask, act)
  dev.upd.c(ip2, Array.get(U32, d, P.IE()))

def dev.upd.a(r: R3) -> Array<U32>:
  R3{d, +ier, rh, rt} = r
  dev.upd.b(ier, Bool.and(nz(U32.and(ier, 1)), U32.is_ne(rh, rt)), get3(d, U.THRE(), P.IP(), P.MASK()))

# Recomputes the UART line, the PLIC pending bits and SEIP.
def dev.upd(d: Array<U32>) -> Array<U32>:
  dev.upd.a(get3(d, U.IER(), U.RXH(), U.RXT()))

def dev.tx.at(+ok: Bool, d: Array<U32>, +k: U32, +b: U32) -> Array<U32>:
  match ok:
    case True{}:
      d[U32.add(U.TX(), k)] <- b
      d[U.TXN()] <- U32.add(k, 1)
      d
    case False{}:
      d

def tx.push.k(+b: U32, p: Array<U32> & U32) -> Array<U32>:
  (d, +k) = p
  dev.tx.at(U32.is_lt(k, 65536), d, k, b)

# Appends a byte to the TX buffer the host drains after each epoch.
def tx.push(d: Array<U32>, +b: U32) -> Array<U32>:
  tx.push.k(U32.and(b, 255), Array.get(U32, d, U.TXN()))

def rx.pop.v(+h: U32, p: Array<U32> & U32) -> R2:
  (d, v) = p
  d[U.RXH()] <- U32.and(U32.add(h, 1), 255)
  R2{d, v, 1}

def rx.pop.k(+any: Bool, d: Array<U32>, +h: U32) -> R2:
  match any:
    case True{}:
      rx.pop.v(h, Array.get(U32, d, U32.add(U.RX(), h)))
    case False{}:
      R2{d, 0, 1}

def rx.pop(r: R2) -> R2:
  R2{d, +h, t} = r
  rx.pop.k(U32.is_ne(h, t), d, h)

def dev.reg.k(p: Array<U32> & U32) -> R2:
  (d, v) = p
  R2{d, v, 1}

# A plain device register read: (d, value, ok = 1).
def dev.reg(d: Array<U32>, +i: U32) -> R2:
  dev.reg.k(Array.get(U32, d, i))

def uart.iir(r: R3) -> R2:
  R3{d, +ier, +rxa, +thre} = r
  +rx = Bool.and(nz(U32.and(ier, 1)), nz(rxa))
  +tx = Bool.and(nz(U32.and(ier, 2)), nz(thre))
  d[U.THRE()] <- sel(Bool.and(Bool.not(rx), tx), 0, thre)
  R2{d, sel(rx, 4, sel(tx, 2, 1)), 1}

def uart.rxa.k(+ier: U32, +rxa: U32, p: Array<U32> & U32) -> R3:
  (d, thre) = p
  R3{d, ier, rxa, thre}

def uart.rxa(r: R3) -> R3:
  R3{d, +ier, h, t} = r
  uart.rxa.k(ier, bit(U32.is_ne(h, t)), Array.get(U32, d, U.THRE()))

def uart.lsr(r: R2) -> R2:
  R2{d, h, t} = r
  R2{d, U32.or(96, bit(U32.is_ne(h, t))), 1}

def uart.rd.k(+reg: U32, +dlab: Bool, d: Array<U32>) -> R2:
  match reg dlab:
    case 0 True{}:
      dev.reg(d, U.DLL())
    case 0 False{}:
      rx.pop(get2(d, U.RXH(), U.RXT()))
    case 1 True{}:
      dev.reg(d, U.DLM())
    case 1 False{}:
      dev.reg(d, U.IER())
    case 2 _:
      uart.iir(uart.rxa(get3(d, U.IER(), U.RXH(), U.RXT())))
    case 3 _:
      dev.reg(d, U.LCR())
    case 4 _:
      dev.reg(d, U.MCR())
    case 5 _:
      uart.lsr(get2(d, U.RXH(), U.RXT()))
    case 6 _:
      R2{d, 176, 1}
    case _ _:
      R2{d, 0, 1}

def uart.rd.a(+reg: U32, p: Array<U32> & U32) -> R2:
  (d, lcr) = p
  uart.rd.k(reg, nz(U32.and(lcr, 128)), d)

def uart.rd(+reg: U32, d: Array<U32>) -> R2:
  uart.rd.a(reg, Array.get(U32, d, U.LCR()))

def uart.wr.k(+reg: U32, +dlab: Bool, d: Array<U32>, +v: U32) -> Array<U32>:
  match reg dlab:
    case 0 True{}:
      d[U.DLL()] <- v
      d
    case 0 False{}:
      d = tx.push(d, v)
      d[U.THRE()] <- 1
      d
    case 1 True{}:
      d[U.DLM()] <- v
      d
    case 1 False{}:
      # the transmitter is always empty, so enabling THRI raises THRE at once
      d[U.IER()] <- U32.and(v, 15)
      d[U.THRE()] <- U32.and(U32.shrn(v, 1n), 1)
      d
    case 3 _:
      d[U.LCR()] <- v
      d
    case 4 _:
      d[U.MCR()] <- v
      d
    case _ _:
      d

def uart.wr.a(+reg: U32, +v: U32, p: Array<U32> & U32) -> Array<U32>:
  (d, lcr) = p
  uart.wr.k(reg, nz(U32.and(lcr, 128)), d, v)

def uart.wr(+reg: U32, +v: U32, d: Array<U32>) -> Array<U32>:
  uart.wr.a(reg, v, Array.get(U32, d, U.LCR()))

def plic.claim(r: R2) -> R2:
  R2{d, +ip, +ie} = r
  +c = U32.and(ip, ie)
  +id = sel(nz(c), U32.from_nat(U32.log2(c)), 0)
  d[P.IP()] <- sel(nz(c), U32.and(ip, U32.not(U32.shln(1, U32.to_nat(id)))), ip)
  R2{d, id, 1}

# o: offset from the PLIC base; one context (hart 0, S-mode).
def plic.rd.k(+o: U32, d: Array<U32>) -> R2:
  match o:
    case 4096:
      dev.reg(d, P.IP())
    case 8192:
      dev.reg(d, P.IE())
    case 2097152:
      dev.reg(d, P.TH())
    case 2097156:
      plic.claim(get2(d, P.IP(), P.IE()))
    case _:
      R2{d, 0, 1}

def plic.done(+id: U32, r: R2) -> Array<U32>:
  R2{d, ie, +mask} = r
  +b = U32.shln(1, shamt(id))
  d[P.MASK()] <- sel(nz(U32.and(ie, b)), U32.and(mask, U32.not(b)), mask)
  d

def plic.wr(+o: U32, +v: U32, d: Array<U32>) -> Array<U32>:
  match o:
    case 8192:
      d[P.IE()] <- U32.and(v, 4294967294)
      d
    case 2097152:
      d[P.TH()] <- v
      d
    case 2097156:
      plic.done(v, get2(d, P.IE(), P.MASK()))
    case _:
      d

def io.upd(r: R2) -> R2:
  R2{d, v, ok} = r
  R2{dev.upd(d), v, ok}

def io.rd.k(+dev: U32, +pa: U32, d: Array<U32>) -> R2:
  match dev:
    case 15:
      io.upd(plic.rd.k(U32.sub(pa, 4026531840), d))
    case 244:
      io.upd(uart.rd(U32.and(pa, 7), d))
    case _:
      R2{d, 0, 0}

# A device read: (d, value, ok). The UART sits at 0xF4000000, the PLIC below it.
def io.rd(+pa: U32, d: Array<U32>) -> R2:
  io.rd.k(sel(U32.is_lt(U32.sub(pa, 4026531840), 67108864), 15, U32.shrn(pa, 24n)), pa, d)

def io.wr.k(+dev: U32, +pa: U32, +v: U32, d: Array<U32>) -> R2:
  match dev:
    case 15:
      R2{dev.upd(plic.wr(U32.sub(pa, 4026531840), v, d)), 0, 1}
    case 244:
      R2{dev.upd(uart.wr(U32.and(pa, 7), v, d)), 0, 1}
    case _:
      R2{d, 0, 0}

def io.wr(+pa: U32, +v: U32, d: Array<U32>) -> R2:
  io.wr.k(sel(U32.is_lt(U32.sub(pa, 4026531840), 67108864), 15, U32.shrn(pa, 24n)), pa, v, d)
