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

# Loads
# -----

def ld.ext(+f3: U32, +v: U32) -> W:
  match f3:
    case 0:
      W{sx(sext8(v)), sext8(v)}
    case 1:
      W{sx(sext16(v)), sext16(v)}
    case 2:
      W{sx(v), v}
    case 4:
      W{0, U32.and(v, 255)}
    case 5:
      W{0, U32.and(v, 65535)}
    case _:
      W{0, v}

def ld.puts(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, w: W) -> Hart:
  W{h, l} = w
  wr.stop(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, h, l)

def ld.r(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +pa: U32) -> Hart:
  (m, +w) = mw
  wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, ld.ext(f3, U32.shrn(w, U32.to_nat(U32.shln(U32.and(pa, 3), 3n)))))

def ld.d(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, r: R2, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32) -> Hart:
  R2{m, lo, hi} = r
  wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, hi, lo)

def ld.ram(+dw: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +pa: U32) -> Hart:
  match dw:
    case True{}:
      ld.d(ph, pl, il, n, md, fv, fp, x, get2(m, U32.shrn(pa, 2n), U32.add(U32.shrn(pa, 2n), 1)), s, d, t, rd)
    case False{}:
      ld.r(ph, pl, il, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, rd, f3, pa)

def ld.io.ok(+ok: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +v: U32, +vh: U32, +vl: U32) -> Hart:
  match ok:
    case True{}:
      ld.puts(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, ld.ext(f3, v))
    case False{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 5, vh, vl)

def ld.io(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>, +rd: U32, +f3: U32, +vh: U32, +vl: U32) -> Hart:
  R2{d, v, ok} = r
  ld.io.ok(nz(ok), ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, f3, v, vh, vl)

def ld.p(+ram: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +vh: U32, +vl: U32, +pa: U32) -> Hart:
  match ram:
    case True{}:
      ld.ram(U32.is_eq(f3, 3), ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, f3, pa)
    case False{}:
      ld.io(ph, pl, il, n, md, fv, fp, x, m, s, io.rd(pa, d), t, rd, f3, vh, vl)

def ld.f(+fault: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +vh: U32, +vl: U32, +pa: U32) -> Hart:
  match fault:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 13, vh, vl)
    case False{}:
      ld.p(U32.is_lt(pa, RAM()), ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, f3, vh, vl, pa)

def ld.w(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +rd: U32, +f3: U32, +vh: U32, +vl: U32) -> Hart:
  Wk{m, s, t, +r} = w
  ld.f(nz(U32.and(r, 1)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, f3, vh, vl, U32.or(r, U32.and(vl, 4095)))

def ld.b(+mis: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +vh: U32, +vl: U32) -> Hart:
  match mis:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 4, vh, vl)
    case False{}:
      ld.w(ph, pl, il, n, md, fv, fp, x, xl(m, s, t, md, 0, vh, vl), d, rd, f3, vh, vl)

def ld.a(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, +bl, +bh} = r
  +im = F.immI(inst)
  +vl = U32.add(bl, im)
  +f3 = F.f3(inst)
  ld.b(nz(U32.and(vl, U32.sub(U32.shln(1, U32.to_nat(U32.and(f3, 3))), 1))), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), f3, U32.add(U32.add(bh, sx(im)), bit(U32.is_lt(vl, bl))), vl)

def i.ld.k(+bad: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match bad:
    case True{}:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case False{}:
      +r = U32.shln(F.rs1(inst), 1n)
      ld.a(ph, pl, il, n, md, fv, fp, get2(x, r, U32.add(r, 1)), m, s, d, t, inst)

def i.ld(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.ld.k(U32.is_eq(F.f3(inst), 7), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# Stores
# ------

# The word after storing the low `f3`-sized part of v at byte (pa & 3).
def st.merge.k(+f3: U32, +sh: Nat, +w: U32, +v: U32) -> U32:
  match f3:
    case 0:
      U32.or(U32.and(w, U32.not(U32.shln(255, sh))), U32.shln(U32.and(v, 255), sh))
    case 1:
      U32.or(U32.and(w, U32.not(U32.shln(65535, sh))), U32.shln(U32.and(v, 65535), sh))
    case _:
      v

def st.merge(+f3: U32, +pa: U32, +w: U32, +v: U32) -> U32:
  st.merge.k(f3, U32.to_nat(U32.shln(U32.and(pa, 3), 3n)), w, v)

def st.rmw(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +pa: U32, +v: U32) -> Hart:
  (m, w) = mw
  m[U32.shrn(pa, 2n)] <- st.merge(f3, pa, w, v)
  nxt(ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def st.ram(+f3: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pa: U32, +sh: U32, +sl: U32) -> Hart:
  match f3:
    case 2:
      m[U32.shrn(pa, 2n)] <- sl
      nxt(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case 3:
      m[U32.shrn(pa, 2n)] <- sl
      m[U32.add(U32.shrn(pa, 2n), 1)] <- sh
      nxt(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case _:
      st.rmw(ph, pl, il, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, f3, pa, sl)

def st.io.ok(+ok: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +vh: U32, +vl: U32) -> Hart:
  match ok:
    case True{}:
      nxt.stop(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case False{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 7, vh, vl)

def st.io(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>, +vh: U32, +vl: U32) -> Hart:
  R2{d, v, ok} = r
  st.io.ok(nz(ok), ph, pl, il, n, md, fv, fp, x, m, s, d, t, vh, vl)

def st.p(+ram: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +vh: U32, +vl: U32, +pa: U32, +sh: U32, +sl: U32) -> Hart:
  match ram:
    case True{}:
      st.ram(f3, ph, pl, il, n, md, fv, fp, x, m, s, d, t, pa, sh, sl)
    case False{}:
      st.io(ph, pl, il, n, md, fv, fp, x, m, s, io.wr(pa, st.merge(f3, 0, 0, sl), d), t, vh, vl)

def st.f(+fault: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +vh: U32, +vl: U32, +pa: U32, +sh: U32, +sl: U32) -> Hart:
  match fault:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 15, vh, vl)
    case False{}:
      st.p(U32.is_lt(pa, RAM()), ph, pl, il, n, md, fv, fp, x, m, s, d, t, f3, vh, vl, pa, sh, sl)

def st.w(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +f3: U32, +vh: U32, +vl: U32, +sh: U32, +sl: U32) -> Hart:
  Wk{m, s, t, +r} = w
  st.f(nz(U32.and(r, 1)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, f3, vh, vl, U32.or(r, U32.and(vl, 4095)), sh, sl)

def st.b(+mis: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +vh: U32, +vl: U32, +sh: U32, +sl: U32) -> Hart:
  match mis:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 6, vh, vl)
    case False{}:
      st.w(ph, pl, il, n, md, fv, fp, x, xl(m, s, t, md, 1, vh, vl), d, f3, vh, vl, sh, sl)

def st.a(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R4, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R4{x, +bl, +bh, +sl, +sh} = r
  +im = F.immS(inst)
  +vl = U32.add(bl, im)
  +f3 = U32.and(F.f3(inst), 3)
  st.b(nz(U32.and(vl, U32.sub(U32.shln(1, U32.to_nat(f3)), 1))), ph, pl, il, n, md, fv, fp, x, m, s, d, t, f3, U32.add(U32.add(bh, sx(im)), bit(U32.is_lt(vl, bl))), vl, sh, sl)

def i.st.k(+bad: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match bad:
    case True{}:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case False{}:
      +a = U32.shln(F.rs1(inst), 1n)
      +b = U32.shln(F.rs2(inst), 1n)
      st.a(ph, pl, il, n, md, fv, fp, get4(x, a, U32.add(a, 1), b, U32.add(b, 1)), m, s, d, t, inst)

def i.st(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.st.k(U32.is_ge(F.f3(inst), 4), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# Atomics (one hart runs at a time, so an AMO is a plain read-modify-write)
# ------------------------------------------------------------------------

def amo.f(+f5: U32, +old: U32, +v: U32) -> U32:
  match f5:
    case 1:
      v
    case 0:
      U32.add(old, v)
    case 4:
      U32.xor(old, v)
    case 12:
      U32.and(old, v)
    case 8:
      U32.or(old, v)
    case 16:
      sel(slt(old, v), old, v)
    case 20:
      sel(slt(old, v), v, old)
    case 24:
      sel(U32.is_lt(old, v), old, v)
    case _:
      sel(U32.is_lt(old, v), v, old)

def sel.w(+c: Bool, +ah: U32, +al: U32, +bh: U32, +bl: U32) -> W:
  W{sel(c, ah, bh), sel(c, al, bl)}

def amo.f64(+f5: U32, +oh: U32, +ol: U32, +vh: U32, +vl: U32) -> W:
  match f5:
    case 1:
      W{vh, vl}
    case 0:
      add64(oh, ol, vh, vl)
    case 4:
      W{U32.xor(oh, vh), U32.xor(ol, vl)}
    case 12:
      W{U32.and(oh, vh), U32.and(ol, vl)}
    case 8:
      W{U32.or(oh, vh), U32.or(ol, vl)}
    case 16:
      sel.w(lt64(oh, ol, vh, vl), oh, ol, vh, vl)
    case 20:
      sel.w(lt64(oh, ol, vh, vl), vh, vl, oh, ol)
    case 24:
      sel.w(ltu64(oh, ol, vh, vl), oh, ol, vh, vl)
    case _:
      sel.w(ltu64(oh, ol, vh, vl), vh, vl, oh, ol)

def amo.sc.go(+ok: Bool, +dw: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  match ok dw:
    case True{} True{}:
      m[U32.shrn(pa, 2n)] <- vl
      m[U32.add(U32.shrn(pa, 2n), 1)] <- vh
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, 0)
    case True{} False{}:
      m[U32.shrn(pa, 2n)] <- vl
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, 0)
    case False{} _:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, 1)

def amo.sc.k(+dw: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dr: Array<U32> & U32, t: Array<U32>, +rd: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  (d, rv) = dr
  d[D.RESV()] <- 0
  amo.sc.go(U32.is_eq(rv, U32.or(pa, 1)), dw, ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, pa, vh, vl)

def amo.kw(+f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  match f5:
    case 2:
      (m, +w) = mw
      d[D.RESV()] <- U32.or(pa, 1)
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sx(w), w)
    case 3:
      (m, w) = mw
      amo.sc.k(False{}, ph, pl, il, n, md, fv, fp, x, m, s, Array.get(U32, d, D.RESV()), t, rd, pa, vh, vl)
    case _:
      (m, +w) = mw
      m[U32.shrn(pa, 2n)] <- amo.f(f5, w, vl)
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sx(w), w)

def amo.kd.st(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +oh: U32, +ol: U32, w: W) -> Hart:
  W{nh, nl} = w
  m[U32.shrn(pa, 2n)] <- nl
  m[U32.add(U32.shrn(pa, 2n), 1)] <- nh
  wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, oh, ol)

def amo.kd(+f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, r: R2, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  match f5:
    case 2:
      R2{m, +lo, +hi} = r
      d[D.RESV()] <- U32.or(pa, 1)
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, hi, lo)
    case 3:
      R2{m, lo, hi} = r
      amo.sc.k(True{}, ph, pl, il, n, md, fv, fp, x, m, s, Array.get(U32, d, D.RESV()), t, rd, pa, vh, vl)
    case _:
      R2{m, +lo, +hi} = r
      amo.kd.st(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, pa, hi, lo, amo.f64(f5, hi, lo, vh, vl))

# (ah, al): the address, for traps; (vh, vl): rs2.
def amo.p(+ram: Bool, +dw: Bool, +f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +ah: U32, +al: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  match ram dw:
    case True{} True{}:
      amo.kd(f5, ph, pl, il, n, md, fv, fp, x, get2(m, U32.shrn(pa, 2n), U32.add(U32.shrn(pa, 2n), 1)), s, d, t, rd, pa, vh, vl)
    case True{} False{}:
      amo.kw(f5, ph, pl, il, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, rd, pa, vh, vl)
    case False{} _:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 5, 7), ah, al)

def amo.f2(+fault: Bool, +dw: Bool, +f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +ah: U32, +al: U32, +pa: U32, +vh: U32, +vl: U32) -> Hart:
  match fault:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 13, 15), ah, al)
    case False{}:
      amo.p(U32.is_lt(pa, RAM()), dw, f5, ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, ah, al, pa, vh, vl)

def amo.w(+dw: Bool, +f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +rd: U32, +ah: U32, +al: U32, +vh: U32, +vl: U32) -> Hart:
  Wk{m, s, t, +r} = w
  amo.f2(nz(U32.and(r, 1)), dw, f5, ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, ah, al, U32.or(r, U32.and(al, 4095)), vh, vl)

def amo.b(+mis: Bool, +dw: Bool, +f5: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +ah: U32, +al: U32, +vh: U32, +vl: U32) -> Hart:
  match mis:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 4, 6), ah, al)
    case False{}:
      amo.w(dw, f5, ph, pl, il, n, md, fv, fp, x, xl(m, s, t, md, sel(U32.is_eq(f5, 2), 0, 1), ah, al), d, rd, ah, al, vh, vl)

def amo.a(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R4, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R4{x, +al, +ah, +vl, +vh} = r
  +dw = U32.is_eq(F.f3(inst), 3)
  amo.b(nz(U32.and(al, sel(dw, 7, 3))), dw, U32.shrn(inst, 27n), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), ah, al, vh, vl)

def i.amo.go(+ok: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match ok:
    case True{}:
      +a = U32.shln(F.rs1(inst), 1n)
      +b = U32.shln(F.rs2(inst), 1n)
      amo.a(ph, pl, il, n, md, fv, fp, get4(x, a, U32.add(a, 1), b, U32.add(b, 1)), m, s, d, t, inst)
    case False{}:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.amo(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.amo.go(Bool.or(U32.is_eq(F.f3(inst), 2), U32.is_eq(F.f3(inst), 3)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# Integer ops
# -----------

def op.v(+key: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +ah: U32, +al: U32, +bh: U32, +bl: U32, +inst: U32) -> Hart:
  match key:
    case 0:
      +l = U32.add(al, bl)
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.add(U32.add(ah, bh), bit(U32.is_lt(l, al))), l)
    case 256:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.sub(U32.sub(ah, bh), bit(U32.is_lt(al, bl))), U32.sub(al, bl))
    case 1:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sll64(ah, al, bl))
    case 2:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, bit(lt64(ah, al, bh, bl)))
    case 3:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, bit(ltu64(ah, al, bh, bl)))
    case 4:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.xor(ah, bh), U32.xor(al, bl))
    case 5:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, srl64(ah, al, bl))
    case 261:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sra64(ah, al, bl))
    case 6:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.or(ah, bh), U32.or(al, bl))
    case 7:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.and(ah, bh), U32.and(al, bl))
    case 8:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, mul64(ah, al, bh, bl))
    case 9:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, mulh64(ah, al, bh, bl))
    case 10:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, mulhsu64(ah, al, bh, bl))
    case 11:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, mulhu64(ah, al, bh, bl))
    case 12:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sdiv64(False{}, ah, al, bh, bl))
    case 13:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, udiv64(False{}, ah, al, bh, bl))
    case 14:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sdiv64(True{}, ah, al, bh, bl))
    case 15:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, udiv64(True{}, ah, al, bh, bl))
    case _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.op.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R4, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R4{x, +al, +ah, +bl, +bh} = r
  op.v(U32.or(U32.shln(U32.shrn(inst, 25n), 3n), F.f3(inst)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), ah, al, bh, bl, inst)

def i.op(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +a = U32.shln(F.rs1(inst), 1n)
  +b = U32.shln(F.rs2(inst), 1n)
  i.op.k(ph, pl, il, n, md, fv, fp, get4(x, a, U32.add(a, 1), b, U32.add(b, 1)), m, s, d, t, inst)

def op32.v(+key: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +a: U32, +b: U32, +inst: U32) -> Hart:
  match key:
    case 0:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.add(a, b))
    case 256:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.sub(a, b))
    case 1:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.shln(a, shamt(b)))
    case 5:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.shrn(a, shamt(b)))
    case 261:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sra(a, shamt(b)))
    case 8:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.mul(a, b))
    case 12:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, div(a, b))
    case 13:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, divu(a, b))
    case 14:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, rem(a, b))
    case 15:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, remu(a, b))
    case _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.op32.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, +a, +b} = r
  op32.v(U32.or(U32.shln(U32.shrn(inst, 25n), 3n), F.f3(inst)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), a, b, inst)

def i.op32(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.op32.k(ph, pl, il, n, md, fv, fp, get2(x, U32.shln(F.rs1(inst), 1n), U32.shln(F.rs2(inst), 1n)), m, s, d, t, inst)

def opi.v(+f3: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +ah: U32, +al: U32, +im: U32, +inst: U32) -> Hart:
  match f3:
    case 0:
      +l = U32.add(al, im)
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.add(U32.add(ah, sx(im)), bit(U32.is_lt(l, al))), l)
    case 1:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sll64(ah, al, U32.shrn(inst, 20n)))
    case 2:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, bit(lt64(ah, al, sx(im), im)))
    case 3:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, 0, bit(ltu64(ah, al, sx(im), im)))
    case 4:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.xor(ah, sx(im)), U32.xor(al, im))
    case 5:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sr64(nz(U32.and(inst, 1073741824)), ah, al, U32.shrn(inst, 20n)))
    case 6:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.or(ah, sx(im)), U32.or(al, im))
    case _:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.and(ah, sx(im)), U32.and(al, im))

def i.opi.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, +al, +ah} = r
  opi.v(F.f3(inst), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), ah, al, F.immI(inst), inst)

def i.opi(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +a = U32.shln(F.rs1(inst), 1n)
  i.opi.k(ph, pl, il, n, md, fv, fp, get2(x, a, U32.add(a, 1)), m, s, d, t, inst)

def opiw.v(+f3: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +a: U32, +im: U32, +inst: U32) -> Hart:
  match f3:
    case 0:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.add(a, im))
    case 1:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, U32.shln(a, shamt(U32.shrn(inst, 20n))))
    case 5:
      wr32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, sel(nz(U32.and(inst, 1073741824)), sra(a, shamt(U32.shrn(inst, 20n))), U32.shrn(a, shamt(U32.shrn(inst, 20n)))))
    case _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.opiw.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  (x, a) = xr
  opiw.v(F.f3(inst), ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), a, F.immI(inst), inst)

def i.opiw(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.opiw.k(ph, pl, il, n, md, fv, fp, Array.get(U32, x, U32.shln(F.rs1(inst), 1n)), m, s, d, t, inst)

# Jumps and branches
# ------------------

def br.t(+tk: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match tk:
    case True{}:
      +o = F.immB(inst)
      +tl = U32.add(pl, o)
      go.to(ph, n, md, fv, fp, x, m, s, d, t, U32.add(U32.add(ph, sx(o)), bit(U32.is_lt(tl, pl))), tl)
    case False{}:
      nxt(ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def br.v(+f3: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +ah: U32, +al: U32, +bh: U32, +bl: U32, +inst: U32) -> Hart:
  match f3:
    case 0:
      br.t(eq64(ah, al, bh, bl), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 1:
      br.t(Bool.not(eq64(ah, al, bh, bl)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 4:
      br.t(lt64(ah, al, bh, bl), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 5:
      br.t(Bool.not(lt64(ah, al, bh, bl)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 6:
      br.t(ltu64(ah, al, bh, bl), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 7:
      br.t(Bool.not(ltu64(ah, al, bh, bl)), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.br.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R4, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R4{x, +al, +ah, +bl, +bh} = r
  br.v(F.f3(inst), ph, pl, il, n, md, fv, fp, x, m, s, d, t, ah, al, bh, bl, inst)

def i.br(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +a = U32.shln(F.rs1(inst), 1n)
  +b = U32.shln(F.rs2(inst), 1n)
  i.br.k(ph, pl, il, n, md, fv, fp, get4(x, a, U32.add(a, 1), b, U32.add(b, 1)), m, s, d, t, inst)

def i.jal(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +o = F.immJ(inst)
  +tl = U32.add(pl, o)
  jmp(ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.add(U32.add(ph, sx(o)), bit(U32.is_lt(tl, pl))), tl)

def i.jalr.k(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, +al, +ah} = r
  +im = F.immI(inst)
  +tl = U32.add(al, im)
  jmp(ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.add(U32.add(ah, sx(im)), bit(U32.is_lt(tl, al))), U32.and(tl, 4294967294))

def i.jalr(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +a = U32.shln(F.rs1(inst), 1n)
  i.jalr.k(ph, pl, il, n, md, fv, fp, get2(x, a, U32.add(a, 1)), m, s, d, t, inst)

# CSRs
# ----

def csr.ok(+num: U32) -> Bool:
  match num:
    case 1:
      True{}
    case 2:
      True{}
    case 3:
      True{}
    case 256:
      True{}
    case 260:
      True{}
    case 261:
      True{}
    case 262:
      True{}
    case 266:
      True{}
    case 320:
      True{}
    case 321:
      True{}
    case 322:
      True{}
    case 323:
      True{}
    case 324:
      True{}
    case 384:
      True{}
    case 3072:
      True{}
    case 3073:
      True{}
    case 3074:
      True{}
    case _:
      False{}

# Counters read the instruction count, which is also time (one tick per
# instruction), and are readable from U-mode regardless of scounteren.
# sstatus reads UXL = 2 and SD = (FS = dirty) in its high word.
def csr.val(+num: U32, +st: U32, +ie: U32, +ip: U32, +tvh: U32, +tvl: U32, +sch: U32, +scl: U32, +eph: U32, +epl: U32, +ca: U32, +tlh: U32, +tll: U32, +sah: U32, +sal: U32, +cen: U32, +env: U32, +n: U32, +nh: U32, +stip: U32, +seip: U32, +fc: U32) -> W:
  match num:
    case 256:
      W{U32.or(2, U32.shln(bit(U32.is_eq(U32.and(st, 24576), 24576)), 31n)), st}
    case 260:
      W{0, ie}
    case 261:
      W{tvh, tvl}
    case 262:
      W{0, cen}
    case 266:
      W{0, env}
    case 320:
      W{sch, scl}
    case 321:
      W{eph, epl}
    case 322:
      W{U32.and(ca, 2147483648), U32.and(ca, 2147483647)}
    case 323:
      W{tlh, tll}
    case 324:
      W{0, U32.or(ip, U32.or(U32.shln(stip, 5n), U32.shln(seip, 9n)))}
    case 384:
      W{sah, sal}
    case 1:
      W{0, U32.and(fc, 31)}
    case 2:
      W{0, U32.and(U32.shrn(fc, 5n), 7)}
    case 3:
      W{0, U32.and(fc, 255)}
    case _:
      W{nh, n}

# The CSR file after writing (vh, vl) to num (num already validated).
def csr.put(+num: U32, +vh: U32, +vl: U32, +pr: U32, +st: U32, +ie: U32, +ip: U32, +tvh: U32, +tvl: U32, +sch: U32, +scl: U32, +eph: U32, +epl: U32, +ca: U32, +tlh: U32, +tll: U32, +sah: U32, +sal: U32, +cen: U32, +env: U32) -> Csr:
  match num:
    case 256:
      Csr{pr, U32.or(U32.and(st, 4294155997), U32.and(vl, 811298)), ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}
    case 260:
      Csr{pr, st, U32.and(vl, 546), ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}
    case 261:
      Csr{pr, st, ie, ip, vh, U32.and(vl, 4294967293), sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}
    case 262:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, vl, env}
    case 266:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, vl}
    case 320:
      Csr{pr, st, ie, ip, tvh, tvl, vh, vl, eph, epl, ca, tlh, tll, sah, sal, cen, env}
    case 321:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, vh, U32.and(vl, 4294967294), ca, tlh, tll, sah, sal, cen, env}
    case 322:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, U32.or(U32.and(vh, 2147483648), U32.and(vl, 2147483647)), tlh, tll, sah, sal, cen, env}
    case 323:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, vh, vl, sah, sal, cen, env}
    case 324:
      Csr{pr, st, ie, U32.or(U32.and(ip, 4294967293), U32.and(vl, 2)), tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}
    case 384:
      # Bare or Sv39 only: a write with any other MODE is ignored, which is
      # how Linux discovers that Sv57 and Sv48 are missing. No ASID bits.
      +ok = Bool.or(U32.is_zero(U32.shrn(vh, 28n)), U32.is_eq(U32.shrn(vh, 28n), 8))
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sel(ok, U32.and(vh, 4026535935), sah), sel(ok, vl, sal), cen, env}
    case _:
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}

def csr.new(+op: U32, +old: U32, +src: U32) -> U32:
  match op:
    case 1:
      src
    case 2:
      U32.or(old, src)
    case _:
      U32.and(old, U32.not(src))

def csr.tlb(+sp: Bool, t: Array<U32>) -> Array<U32>:
  match sp:
    case True{}:
      tlb.flush(t)
    case False{}:
      t

# Any CSR write ends the slice and drops the fetch tag; a satp write also
# flushes the TLB.
def csr.fin(+sp: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +oh: U32, +ol: U32) -> Hart:
  Csr{+pr, +st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, +sah, sal, cen, env} = s
  wr.stop(ph, pl, il, n, md.of(pr, st, sah), 1, fp, x, m, Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, d, csr.tlb(sp, t), rd, oh, ol)

def csr.fcsr(+num: U32, +v: U32, +fc: U32) -> U32:
  match num:
    case 1:
      U32.or(U32.and(fc, 224), U32.and(v, 31))
    case 2:
      U32.or(U32.and(fc, 31), U32.shln(U32.and(v, 7), 5n))
    case _:
      U32.and(v, 255)

def fs.dirty(s: Csr) -> Csr:
  Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env} = s
  Csr{pr, U32.or(st, 24576), ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}

# fflags, frm, fcsr: they live at x[128]; writing them dirties the FP state.
def csr.fpw(+num: U32, +v: U32, +fc: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +oh: U32, +ol: U32) -> Hart:
  x[X.FCSR()] <- csr.fcsr(num, v, fc)
  wr(ph, pl, il, n, U32.or(md, 48), fv, fp, x, m, fs.dirty(s), d, t, rd, oh, ol)

def csr.go(+ok: Bool, +write: Bool, +fpc: Bool, +num: U32, old: W, +sh: U32, +sl: U32, +op: U32, +fc: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +inst: U32) -> Hart:
  match ok write fpc:
    case False{} _ _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case True{} False{} _:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, old)
    case True{} True{} False{}:
      W{+oh, +ol} = old
      Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env} = s
      csr.fin(U32.is_eq(num, 384), ph, pl, il, n, fv, fp, x, m, csr.put(num, csr.new(op, oh, sh), csr.new(op, ol, sl), pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env), d, t, rd, oh, ol)
    case True{} True{} True{}:
      W{+oh, +ol} = old
      csr.fpw(num, csr.new(op, ol, sl), fc, ph, pl, il, n, md, fv, fp, x, m, s, d, t, rd, oh, ol)

def csr.c(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>, +sh: U32, +sl: U32, +fc: U32, +inst: U32) -> Hart:
  Csr{+pr, +st, +ie, +ip, +tvh, +tvl, +sch, +scl, +eph, +epl, +ca, +tlh, +tll, +sah, +sal, +cen, +env} = s
  R3{d, nh, stip, seip} = r
  +num = U32.shrn(inst, 20n)
  +op = U32.and(F.f3(inst), 3)
  +write = Bool.or(U32.is_eq(op, 1), nz(F.rs1(inst)))
  +fpc = U32.is_lt(num, 4)
  +ok = Bool.and(Bool.and(csr.ok(num), Bool.or(Bool.not(fpc), nz(U32.and(md, 16)))), Bool.and(U32.is_le(U32.and(U32.shrn(num, 8n), 3), pr), Bool.or(Bool.not(write), U32.is_ne(U32.shrn(num, 10n), 3))))
  csr.go(ok, write, fpc, num, csr.val(num, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env, n, nh, stip, seip, fc), sh, sl, op, fc, ph, pl, il, n, md, fv, fp, x, m, Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, d, t, F.rd(inst), inst)

def csr.b(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R3, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R3{x, +rl, +rh, +fc} = r
  +imm = nz(U32.and(inst, 16384))
  csr.c(ph, pl, il, n, md, fv, fp, x, m, s, get3(d, D.NH(), D.STIP(), D.SEIP()), t, sel(imm, 0, rh), sel(imm, F.rs1(inst), rl), fc, inst)

def i.csr(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  +a = U32.shln(F.rs1(inst), 1n)
  csr.b(ph, pl, il, n, md, fv, fp, get3(x, a, U32.add(a, 1), X.FCSR()), m, s, d, t, inst)

# SBI: the firmware interface, answered by the emulator
# -----------------------------------------------------

# a0 = (eh, el), a1 = (vh, vl); SBI calls end the slice.
def sbi.ret(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +eh: U32, +el: U32, +vh: U32, +vl: U32) -> Hart:
  x[20] <- el
  x[21] <- eh
  x[22] <- vl
  x[23] <- vh
  +npl = U32.add(pl, il)
  Hart{False{}, U32.add(ph, bit(U32.is_lt(npl, il))), npl, n, md, fv, fp, x, m, s, d, t}

def sbi.ok(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +vh: U32, +vl: U32) -> Hart:
  sbi.ret(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 0, vh, vl)

# SBI errors are small negative numbers: e = 2 is SBI_ERR_NOT_SUPPORTED.
def sbi.err(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +e: U32) -> Hart:
  sbi.ret(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 4294967295, neg(e), 0, 0)

def sbi.probe(+eid: U32) -> U32:
  match eid:
    case 16:
      1
    case 1414090053:
      1
    case 7557193:
      1
    case 1380339267:
      1
    case 4739917:
      1
    case 1397904212:
      1
    case _:
      0

def sbi.base(+fid: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0: U32) -> Hart:
  match fid:
    case 0:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 16777216)
    case 1:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 87)
    case 2:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 1)
    case 3:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, sbi.probe(a0))
    case _:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 0)

# Arms the timer at (hi, lo); STIP clears until time reaches it again.
def sbi.timer(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dr: Array<U32> & U32, t: Array<U32>, +lo: U32, +hi: U32) -> Hart:
  (d, nh) = dr
  d[D.CL()] <- lo
  d[D.CH()] <- hi
  d[D.STIP()] <- bit(ge64(nh, n, hi, lo))
  sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 0)

def sbi.getc.k(+empty: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>) -> Hart:
  R2{d, v, ok} = r
  sbi.ret(ph, pl, il, n, md, fv, fp, x, m, s, dev.upd(d), t, sel(empty, 4294967295, 0), sel(empty, 4294967295, v), 0, 0)

def sbi.getc(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>) -> Hart:
  R2{d, +h, +tl} = r
  sbi.getc.k(U32.is_eq(h, tl), ph, pl, il, n, md, fv, fp, x, m, s, rx.pop(R2{d, h, tl}), t)

# One hart: an IPI or remote fence that targets hart 0 acts locally.
def sbi.self(+mask: U32, +bh: U32, +bl: U32) -> Bool:
  Bool.or(eq64(bh, bl, 4294967295, 4294967295), Bool.and(eq64(bh, bl, 0, 0), nz(U32.and(mask, 1))))

def sbi.ipi(+hit: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Csr{pr, st, ie, +ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env} = s
  sbi.ok(ph, pl, il, n, md, fv, fp, x, m, Csr{pr, st, ie, sel(hit, U32.or(ip, 2), ip), tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, d, t, 0, 0)

def sbi.hsm(+fid: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0: U32) -> Hart:
  match fid:
    case 0:
      sbi.err(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0), 6, 3))
    case 2:
      sbi.ret(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0), 0, 4294967295), sel(U32.is_zero(a0), 0, 4294967293), 0, 0)
    case _:
      sbi.err(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 2)

def sbi.halt(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +code: U32) -> Hart:
  d[D.EXIT()] <- code
  sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 0, 0)

def sbi.k(+eid: U32, +fid: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0h: U32, +a0l: U32, +a1h: U32, +a1l: U32) -> Hart:
  match eid:
    case 16:
      sbi.base(fid, ph, pl, il, n, md, fv, fp, x, m, s, d, t, a0l)
    case 1414090053:
      sbi.timer(ph, pl, il, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t, a0l, a0h)
    case 0:
      sbi.timer(ph, pl, il, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t, a0l, a0h)
    case 1:
      sbi.ok(ph, pl, il, n, md, fv, fp, x, m, s, tx.push(d, a0l), t, 0, 0)
    case 2:
      sbi.getc(ph, pl, il, n, md, fv, fp, x, m, s, get2(d, U.RXH(), U.RXT()), t)
    case 8:
      sbi.halt(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 1)
    case 7557193:
      sbi.ipi(sbi.self(a0l, a1h, a1l), ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case 1380339267:
      sbi.ok(ph, pl, il, n, md, 1, fp, x, m, s, d, tlb.flush(t), 0, 0)
    case 4739917:
      sbi.hsm(fid, ph, pl, il, n, md, fv, fp, x, m, s, d, t, a0l)
    case 1397904212:
      sbi.halt(ph, pl, il, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0l), 1, 3))
    case _:
      sbi.err(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 2)

def sbi.b(+eid: U32, +fid: U32, +a0l: U32, +a0h: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  R2{x, a1l, a1h} = r
  sbi.k(eid, fid, ph, pl, il, n, md, fv, fp, x, m, s, d, t, a0h, a0l, a1h, a1l)

def sbi.a(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R4, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  R4{x, eid, fid, a0l, a0h} = r
  sbi.b(eid, fid, a0l, a0h, ph, pl, il, n, md, fv, fp, get2(x, 22, 23), m, s, d, t)

# a7 = EID, a6 = FID, a0 and a1 the arguments.
def sbi(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  sbi.a(ph, pl, il, n, md, fv, fp, get4(x, 34, 32, 20, 21), m, s, d, t)

# Privileged instructions
# -----------------------

def i.sret(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Csr{pr, +st, ie, ip, tvh, tvl, sch, scl, +eph, +epl, ca, tlh, tll, +sah, sal, cen, env} = s
  +np = U32.and(U32.shrn(st, 8n), 1)
  +st2 = U32.or(U32.and(st, 4294967005), U32.or(32, U32.and(U32.shrn(st, 4n), 2)))
  Hart{False{}, eph, epl, n, md.of(np, st2, sah), 1, fp, x, m, Csr{np, st2, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, d, t}

def i.wfi(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  d[D.WFI()] <- 1
  nxt.stop(ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def i.sfence(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  nxt(ph, pl, il, n, md, 1, fp, x, m, s, d, tlb.flush(t))

def i.ecall(+user: Bool, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match user:
    case True{}:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 8, 0, 0)
    case False{}:
      sbi(ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def i.sup.k(+which: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match which:
    case 0:
      i.sret(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case 1:
      i.wfi(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case _:
      i.sfence(ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def i.sup(+bad: Bool, +which: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match bad:
    case True{}:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case False{}:
      i.sup.k(which, ph, pl, il, n, md, fv, fp, x, m, s, d, t)

def i.priv.k(+inst: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +user: Bool) -> Hart:
  match inst:
    case 115:
      i.ecall(user, ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case 1048691:
      trap(ph, pl, il, n, md, fv, fp, x, m, s, d, t, 3, ph, pl)
    case 270532723:
      i.sup(user, 0, ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 273678451:
      i.sup(user, 1, ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      i.sup(Bool.or(user, U32.is_ne(U32.shrn(inst, 25n), 9)), 2, ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# S-mode-only instructions: 0 sret, 1 wfi, 2 sfence.vma
def i.sys.k(+f3: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match f3:
    case 0:
      i.priv.k(inst, ph, pl, il, n, md, fv, fp, x, m, s, d, t, U32.is_zero(U32.and(md, 1)))
    case 4:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      i.csr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

def i.sys(+ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.sys.k(F.f3(inst), ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# Decode and execute
# ------------------

def exec.op(+op: U32, +inst: U32, +ph: U32, +pl: U32, +il: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match op:
    case 19:
      i.opi(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 51:
      i.op(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 3:
      i.ld(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 35:
      i.st(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 99:
      i.br(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 27:
      i.opiw(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 59:
      i.op32(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 55:
      wr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), sx(U32.and(inst, 4294963200)), U32.and(inst, 4294963200))
    case 23:
      wr.w(ph, pl, il, n, md, fv, fp, x, m, s, d, t, F.rd(inst), add64(ph, pl, sx(U32.and(inst, 4294963200)), U32.and(inst, 4294963200)))
    case 111:
      i.jal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 103:
      i.jalr(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 115:
      i.sys(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 47:
      i.amo(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)
    case 15:
      # fence, fence.i: one owner, no decode cache, so nothing to order
      nxt(ph, pl, il, n, md, fv, fp, x, m, s, d, t)
    case _:
      illegal(ph, pl, il, n, md, fv, fp, x, m, s, d, t, inst)

# Fetch
# -----
# The word holding pc gives either a 32-bit instruction (low two bits 11) or
# a compressed one, which RVC.C.expand turns into its 32-bit equivalent (0
# when reserved: illegal, with the halfword in stval). A 32-bit instruction
# at pc = 2 mod 4 takes its upper half from the next word, which on the
# last halfword of a page means translating the next page as well.

def exec.c(+inst: U32, +h: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match inst:
    case 0:
      trap(ph, pl, 2, n, md, fv, fp, x, m, s, d, t, 2, 0, h)
    case _:
      exec.op(U32.and(inst, 127), inst, ph, pl, 2, n, md, fv, fp, x, m, s, d, t)

def exec.x(+lo: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  (m, +w) = mw
  +inst = U32.or(lo, U32.shln(w, 16n))
  exec.op(U32.and(inst, 127), inst, ph, pl, 4, n, md, fv, fp, x, m, s, d, t)

def fetch.x2.ok(+ram: Bool, +lo: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pg: U32) -> Hart:
  match ram:
    case True{}:
      exec.x(lo, ph, pl, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pg, 2n)), s, d, t)
    case False{}:
      +ql = U32.add(pl, 2)
      trap(ph, pl, 4, n, md, fv, fp, x, m, s, d, t, 1, U32.add(ph, bit(U32.is_lt(ql, 2))), ql)

# stval must name the second page: that is the one Linux has to map.
def fetch.x2.f(+fault: Bool, +lo: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +r: U32) -> Hart:
  match fault:
    case True{}:
      +ql = U32.add(pl, 2)
      trap(ph, pl, 4, n, md, fv, fp, x, m, s, d, t, 12, U32.add(ph, bit(U32.is_lt(ql, 2))), ql)
    case False{}:
      fetch.x2.ok(U32.is_lt(r, RAM()), lo, ph, pl, n, md, fv, fp, x, m, s, d, t, r)

def fetch.x2.w(+lo: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>) -> Hart:
  Wk{m, s, t, +r} = w
  fetch.x2.f(nz(U32.and(r, 1)), lo, ph, pl, n, md, fv, fp, x, m, s, d, t, r)

def fetch.x(+cross: Bool, +lo: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match cross:
    case False{}:
      exec.x(lo, ph, pl, n, md, fv, fp, x, Array.get(U32, m, U32.add(U32.shrn(U32.or(fp, U32.and(pl, 4095)), 2n), 1)), s, d, t)
    case True{}:
      +ql = U32.add(pl, 2)
      fetch.x2.w(lo, ph, pl, n, md, fv, fp, x, xl(m, s, t, md, 2, U32.add(ph, bit(U32.is_lt(ql, 2))), ql), d)

def fetch.hi(+full: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +w: U32) -> Hart:
  match full:
    case False{}:
      exec.c(RVC.C.expand(U32.shrn(w, 16n)), U32.shrn(w, 16n), ph, pl, n, md, fv, fp, x, m, s, d, t)
    case True{}:
      fetch.x(U32.is_eq(U32.and(pl, 4095), 4094), U32.shrn(w, 16n), ph, pl, n, md, fv, fp, x, m, s, d, t)

def fetch.lo(+full: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +w: U32) -> Hart:
  match full:
    case True{}:
      exec.op(U32.and(w, 127), w, ph, pl, 4, n, md, fv, fp, x, m, s, d, t)
    case False{}:
      exec.c(RVC.C.expand(U32.and(w, 65535)), U32.and(w, 65535), ph, pl, n, md, fv, fp, x, m, s, d, t)

def fetch.h(+odd: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +w: U32) -> Hart:
  match odd:
    case False{}:
      fetch.lo(U32.is_eq(U32.and(w, 3), 3), ph, pl, n, md, fv, fp, x, m, s, d, t, w)
    case True{}:
      fetch.hi(U32.is_eq(U32.and(U32.shrn(w, 16n), 3), 3), ph, pl, n, md, fv, fp, x, m, s, d, t, w)

def fetch.k(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  (m, +w) = mw
  fetch.h(nz(U32.and(pl, 2)), ph, pl, n, md, fv, fp, x, m, s, d, t, w)

def fetch.ok(+ram: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pg: U32) -> Hart:
  match ram:
    case True{}:
      fetch.k(ph, pl, n, md, U32.or(U32.and(pl, 4294963200), U32.shln(U32.and(ph, 127), 1n)), pg, x, Array.get(U32, m, U32.shrn(U32.or(pg, U32.and(pl, 4095)), 2n)), s, d, t)
    case False{}:
      trap(ph, pl, 4, n, md, fv, fp, x, m, s, d, t, 1, ph, pl)

def fetch.f(+fault: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +r: U32) -> Hart:
  match fault:
    case True{}:
      trap(ph, pl, 4, n, md, fv, fp, x, m, s, d, t, 12, ph, pl)
    case False{}:
      fetch.ok(U32.is_lt(r, RAM()), ph, pl, n, md, fv, fp, x, m, s, d, t, r)

def fetch.w(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>) -> Hart:
  Wk{m, s, t, +r} = w
  fetch.f(nz(U32.and(r, 1)), ph, pl, n, md, fv, fp, x, m, s, d, t, r)

def step.f(+hit: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match hit:
    case True{}:
      fetch.k(ph, pl, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(U32.or(fp, U32.and(pl, 4095)), 2n)), s, d, t)
    case False{}:
      fetch.w(ph, pl, n, md, fv, fp, x, xl(m, s, t, md, 2, ph, pl), d)

# One instruction.
def step(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  step.f(U32.is_eq(U32.or(U32.and(pl, 4294963200), U32.shln(U32.and(ph, 127), 1n)), fv), ph, pl, U32.add(n, 1), md, fv, fp, x, m, s, d, t)

# Up to k instructions; stops early when an instruction ends the slice.
def run(k: Nat, h: Hart) -> Hart:
  match k h:
    case 0n _:
      h
    case 1n+p Hart{True{}, ph, pl, n, md, fv, fp, x, m, s, d, t}:
      run(p, step(ph, pl, n, md, fv, fp, x, m, s, d, t))
    case 1n+p Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}:
      Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}

# Slices
# ------
# A slice runs until the next timer deadline, the end of the epoch budget, or
# an instruction that may change which interrupt is next. Between slices the
# hart takes interrupts and sleeps through WFI by jumping time to the deadline:
# time is the instruction count, so an idle guest costs nothing to wait.

def slice.fin(+left: U32, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart:
  (d, ex) = de
  Hart{Bool.and(nz(left), U32.is_zero(ex)), ph, pl, n, md, fv, fp, x, m, s, d, t}

def slice.post(+n0: U32, +nh: U32, +left: U32, h: Hart) -> Hart:
  Hart{go, ph, pl, +n, md, fv, fp, x, m, s, d, t} = h
  +left2 = U32.sub(left, U32.sub(n, n0))
  d[D.LEFT()] <- left2
  d[D.NH()] <- U32.add(nh, bit(U32.is_lt(n, n0)))
  slice.fin(left2, ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

# Runs one slice of k = min(left, until the deadline, until n wraps) steps.
def slice.run(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32, +due: Bool, +left: U32) -> Hart:
  +dlo = U32.sub(cl, n)
  +dhi = U32.sub(U32.sub(ch, nh), bit(U32.is_lt(cl, n)))
  +k1 = sel(Bool.or(due, nz(dhi)), left, umin(left, dlo))
  +k = sel(U32.is_zero(n), k1, umin(k1, U32.sub(0, n)))
  slice.post(n, nh, left, run(U32.to_nat(k), Hart{True{}, ph, pl, n, md, fv, fp, x, m, s, d, t}))

def slice.idle(+armed: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32) -> Hart:
  match armed:
    case True{}:
      d[D.NH()] <- ch
      Hart{True{}, ph, pl, cl, md, fv, fp, x, m, s, d, t}
    case False{}:
      # asleep with nothing that could wake it: hand the hart to the host
      d[D.EXIT()] <- 2
      Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}

# irq: an enabled interrupt is pending; wake: one is pending at all
def slice.c(+irq: Bool, +wake: Bool, +wfi: Bool, +ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pend: U32, +nh: U32, +cl: U32, +ch: U32, +due: Bool, +left: U32) -> Hart:
  match irq wake wfi:
    case True{} _ _:
      d[D.WFI()] <- 0
      trap(ph, pl, 4, n, md, fv, fp, x, m, s, d, t, U32.or(2147483648, sel(nz(U32.and(pend, 512)), 9, sel(nz(U32.and(pend, 2)), 1, 5))), 0, 0)
    case False{} True{} True{}:
      d[D.WFI()] <- 0
      Hart{True{}, ph, pl, n, md, fv, fp, x, m, s, d, t}
    case False{} False{} True{}:
      slice.idle(Bool.and(Bool.not(due), Bool.not(Bool.and(U32.is_eq(cl, 4294967295), U32.is_eq(ch, 4294967295)))), ph, pl, n, md, fv, fp, x, m, s, d, t, nh, cl, ch)
    case False{} _ False{}:
      slice.run(ph, pl, n, md, fv, fp, x, m, s, d, t, nh, cl, ch, due, left)

def slice.b(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32, +due: Bool) -> Hart:
  Csr{+pr, +st, +ie, +ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env} = s
  R3{d, seip, wfi, left} = r
  +pend = U32.and(U32.or(ip, U32.or(U32.shln(bit(due), 5n), U32.shln(seip, 9n))), ie)
  +on = Bool.or(U32.is_zero(pr), nz(U32.and(st, 2)))
  slice.c(Bool.and(nz(pend), on), nz(pend), nz(wfi), ph, pl, n, md, fv, fp, x, m, Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env}, d, t, pend, nh, cl, ch, due, left)

def slice.a(+ph: U32, +pl: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>) -> Hart:
  R3{d, +nh, +cl, +ch} = r
  +due = ge64(nh, n, ch, cl)
  d[D.STIP()] <- bit(due)
  slice.b(ph, pl, n, md, fv, fp, x, m, s, get3(d, D.SEIP(), D.WFI(), D.LEFT()), t, nh, cl, ch, due)

def slice(h: Hart) -> Hart:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  slice.a(ph, pl, n, md, fv, fp, x, m, s, get3(dev.upd(d), D.NH(), D.CL(), D.CH()), t)

# An epoch: slices until the budget in D.LEFT is spent or the host is needed
# (D.EXIT: 1 power off, 2 asleep for good, 3 reboot). k bounds the slices.
def epoch(k: Nat, h: Hart) -> Hart:
  match k h:
    case 0n _:
      h
    case 1n+p Hart{True{}, ph, pl, n, md, fv, fp, x, m, s, d, t}:
      epoch(p, slice(Hart{True{}, ph, pl, n, md, fv, fp, x, m, s, d, t}))
    case 1n+p Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}:
      Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}

# Host interface
# --------------

# A hart at reset: S-mode, MMU off, FP off, a0 = hart id, a1 = the device tree.
def Hart.new(m: Array<U32>, +hid: U32, +dtb: U32, +pc: U32) -> Hart:
  x = [0 : U32*256n]
  x[20] <- hid
  x[22] <- dtb
  d = [0 : U32*131072n]
  d[D.CL()] <- 4294967295
  d[D.CH()] <- 4294967295
  d[D.HART()] <- hid
  Hart{True{}, 0, pc, 0, 1, 1, 1, x, m, Csr{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, d, [0 : U32*512n]}

def arm.a(+budget: U32, ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart:
  (d, ex) = de
  d[D.LEFT()] <- budget
  Hart{U32.is_zero(ex), ph, pl, n, md, fv, fp, x, m, s, d, t}

# Gives the hart a budget of instructions for the next epoch (a hart that
# has powered off stays parked).
def Hart.arm(+budget: U32, h: Hart) -> Hart:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  arm.a(budget, ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

def drain.go(k: Nat, dv: Array<U32> & U32, +i: U32, acc: List<&2, U32>) -> Array<U32> & List<&2, U32>:
  match k:
    case 0n:
      (d, v) = dv
      (d, acc)
    case 1n+p:
      (d, v) = dv
      drain.go(p, Array.get(U32, d, U32.sub(i, 1)), U32.sub(i, 1), v <> acc)

def drain.fin(ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: Array<U32> & List<&2, U32>, t: Array<U32>) -> Hart & List<&2, U32>:
  (d, bs) = r
  d[U.TXN()] <- 0
  (Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}, bs)

def drain.a(ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dk: Array<U32> & U32, t: Array<U32>) -> Hart & List<&2, U32>:
  (d, +k) = dk
  +e = U32.add(U.TX(), U32.sub(k, 1))
  drain.fin(ph, pl, n, md, fv, fp, x, m, s, drain.go(U32.to_nat(k), Array.get(U32, d, e), e, Nil{}), t)

# Takes the bytes the guest wrote to the console since the last drain.
def Hart.drain(h: Hart) -> Hart & List<&2, U32>:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  drain.a(ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, U.TXN()), t)

def rx.push.k(room: Bool, d: Array<U32>, +b: U32, +tl: U32) -> Array<U32>:
  match room:
    case True{}:
      d[U32.add(U.RX(), tl)] <- b
      d[U.RXT()] <- U32.and(U32.add(tl, 1), 255)
      d
    case False{}:
      d

def rx.push(+b: U32, r: R2) -> Array<U32>:
  R2{d, hd, +tl} = r
  rx.push.k(U32.is_ne(U32.and(U32.add(tl, 1), 255), hd), d, b, tl)

def feed.go(bs: List<&2, U32>, d: Array<U32>) -> Array<U32>:
  match bs:
    case Nil{}:
      d
    case Con{b, rest}:
      feed.go(rest, rx.push(b, get2(d, U.RXH(), U.RXT())))

# Queues bytes on the UART's receive side; a full ring (255) drops the rest.
def Hart.feed(bs: List<&2, U32>, h: Hart) -> Hart:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, dev.upd(feed.go(bs, d)), t}

def exit.a(ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart & U32:
  (d, e) = de
  (Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}, e)

# Why the last epoch ended early (0: it did not; see `epoch`).
def Hart.exit(h: Hart) -> Hart & U32:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  exit.a(ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

def count.a(ph: U32, pl: U32, +n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dh: Array<U32> & U32, t: Array<U32>) -> Hart & (U32 & U32):
  (d, nh) = dh
  (Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}, (nh, n))

# Instructions retired so far, as (hi, lo).
def Hart.count(h: Hart) -> Hart & (U32 & U32):
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  count.a(ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t)

# Fleets
# ------
# Independent machines (each a hart with its own RAM) as a balanced binary
# tree. An epoch over the fleet is one fork tree that ends in the flat
# per-hart loops: called with `!`, one bang runs one machine per GPU lane.

type Fleet is Type:
  VM{h: Hart}
  Two{a: Fleet, b: Fleet}

def Fleet.epoch(+k: Nat, +budget: U32, f: Fleet) -> Fleet:
  match f:
    case VM{h}:
      VM{epoch(k, Hart.arm(budget, h))}
    case Two{a, b}:
      x y = Fleet.epoch(k, budget, a) Fleet.epoch(k, budget, b)
      Two{x, y}

type Tally is Type:
  Tally{f: Fleet, live: U32, lo: U32, out: List<&2, U32>}

def tally.vm.c(r: Hart & (U32 & U32), +live: U32, out: List<&2, U32>) -> Tally:
  (h, c) = r
  (hi, lo) = c
  Tally{VM{h}, live, lo, out}

def tally.vm(r: Hart & U32, out: List<&2, U32>) -> Tally:
  (h, +ex) = r
  tally.vm.c(Hart.count(h), bit(U32.is_zero(ex)), out)

def tally.two(ta: Tally, tb: Tally) -> Tally:
  Tally{a, la, ca, oa} = ta
  Tally{b, lb, cb, ob} = tb
  Tally{Two{a, b}, U32.add(la, lb), U32.add(ca, cb), List.append(&2, U32, oa, ob)}

def tally.drained(r: Hart & List<&2, U32>) -> Tally:
  (h, out) = r
  tally.vm(Hart.exit(h), out)

# Drains every machine's console (in tree order) and counts the machines
# still running and the instructions retired (low words, summed).
def Fleet.tally(f: Fleet) -> Tally:
  match f:
    case VM{h}:
      tally.drained(Hart.drain(h))
    case Two{a, b}:
      tally.two(Fleet.tally(a), Fleet.tally(b))

# Tracing (WILTEE_TRACE=1): one line per epoch on stderr.

def trace.line(+ph: U32, +pl: U32, +n: U32, s: Csr) -> String:
  Csr{pr, st, ie, ip, tvh, tvl, sch, scl, eph, epl, ca, tlh, tll, sah, sal, cen, env} = s
  "[trace] n=" ++ U32.show(n) ++ " pc=" ++ U32.hex(ph) ++ ":" ++ U32.hex(pl) ++ " priv=" ++ U32.show(pr) ++ " scause=" ++ U32.hex(ca) ++ " sepc=" ++ U32.hex(eph) ++ ":" ++ U32.hex(epl) ++ " stval=" ++ U32.hex(tlh) ++ ":" ++ U32.hex(tll)

def trace.pick(on: Bool, +ph: U32, +pl: U32, +n: U32, s: Csr) -> String:
  match on:
    case True{}:
      trace.line(ph, pl, n, s)
    case False{}:
      ""

def trace.a(+on: Bool, +ph: U32, +pl: U32, +n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, +s: Csr, d: Array<U32>, t: Array<U32>) -> Hart & String:
  (Hart{False{}, ph, pl, n, md, fv, fp, x, m, s, d, t}, trace.pick(on, ph, pl, n, s))

def trace.b(ph: U32, pl: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart & String:
  (d, on) = de
  trace.a(nz(on), ph, pl, n, md, fv, fp, x, m, s, d, t)

# The trace line for this epoch, or "" when tracing is off.
def Hart.trace(h: Hart) -> Hart & String:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  trace.b(ph, pl, n, md, fv, fp, x, m, s, Array.get(U32, d, D.TRACE()), t)

def Hart.set_trace(+on: U32, h: Hart) -> Hart:
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t} = h
  d[D.TRACE()] <- on
  Hart{go, ph, pl, n, md, fv, fp, x, m, s, d, t}
