import Base

# One RV32IMA hart (Zicsr, Zifencei; S and U modes; Sv32) as a total, pure
# state transformer. wiltee plays the M-mode firmware itself: every trap lands
# in S-mode and an S-mode ECALL is answered here as an SBI call.
#
# Nothing in this file is @unsafe: `run` and `epoch` count down a Nat, so the
# checker proves that every epoch halts.

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

# high word of the 64-bit product, from 16-bit limbs (Bend has no U64)
def mulhu(+a: U32, +b: U32) -> U32:
  +a0 = U32.and(a, 65535)
  +a1 = U32.shrn(a, 16n)
  +b0 = U32.and(b, 65535)
  +b1 = U32.shrn(b, 16n)
  +lh = U32.mul(a0, b1)
  +hl = U32.mul(a1, b0)
  +mid = U32.add(U32.add(U32.shrn(U32.mul(a0, b0), 16n), U32.and(lh, 65535)), U32.and(hl, 65535))
  U32.add(U32.add(U32.mul(a1, b1), U32.add(U32.shrn(lh, 16n), U32.shrn(hl, 16n))), U32.shrn(mid, 16n))

def mulh(+a: U32, +b: U32) -> U32:
  U32.sub(U32.sub(mulhu(a, b), sel(isneg(a), b, 0)), sel(isneg(b), a, 0))

def mulhsu(+a: U32, +b: U32) -> U32:
  U32.sub(mulhu(a, b), sel(isneg(a), b, 0))

def uabs(+a: U32) -> U32:
  sel(isneg(a), neg(a), a)

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

# Multi-reads: an array read hands the array back, so N reads fold into one
# record instead of N continuation defs at every call site.
# --------------------------------------------------------------------------

type R2 is Type:
  R2{a: Array<U32>, u: U32, v: U32}

type R3 is Type:
  R3{a: Array<U32>, u: U32, v: U32, w: U32}

def get2.b(+u: U32, p: Array<U32> & U32) -> R2:
  (a, v) = p
  R2{a, u, v}

def get2.a(+j: U32, p: Array<U32> & U32) -> R2:
  (a, u) = p
  get2.b(u, Array.get(U32, a, j))

def get2(a: Array<U32>, +i: U32, +j: U32) -> R2:
  get2.a(j, Array.get(U32, a, i))

def get3.b(+u: U32, +k: U32, r: R2) -> R3:
  R2{a, v, w} = r
  R3{a, u, v, w}

def get3.a(+j: U32, +k: U32, p: Array<U32> & U32) -> R3:
  (a, u) = p
  get3.b(u, k, get2(a, j, k))

def get3(a: Array<U32>, +i: U32, +j: U32, +k: U32) -> R3:
  get3.a(j, k, Array.get(U32, a, i))

# State
# -----

# The S-mode CSRs. `ip` holds only SSIP; STIP and SEIP live in the device
# words (D.STIP, D.SEIP), where the timer and the PLIC raise them.
type Csr is Data:
  Csr{priv: U32, st: U32, ie: U32, ip: U32, tvec: U32, scr: U32, epc: U32, cause: U32, tval: U32, satp: U32, cen: U32, env: U32}

# go: keep running (the slice loop ends a slice on False)
# n:  low word of the instruction count, which is also the guest's `time`
# md: access mode for the hot path: bit0 S-mode, bit1 SUM, bit2 MXR, bit3 Sv32 on
# fv, fp: virtual and physical page of the last fetch (fv = 1: none)
# x: registers, m: RAM, s: CSRs, d: device words, t: TLB
type Hart is Type:
  Hart{go: Bool, pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>}

# A translation: the arrays it may touch, and r = physical page, or 1 on a fault.
type Wk is Type:
  Wk{m: Array<U32>, s: Csr, t: Array<U32>, r: U32}

# RAM size in bytes; must match the array built by Hart.new.
def RAM() -> U32:
  134217728

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
# RX ring: 256 bytes at 256. TX buffer: 65536 bytes at 65536.
def U.RX() -> U32:
  256
def U.TX() -> U32:
  65536

def md.of(+priv: U32, +st: U32, +satp: U32) -> U32:
  U32.or(U32.or(priv, U32.and(U32.shrn(st, 17n), 6)), U32.and(U32.shrn(satp, 28n), 8))

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

# Enters the S-mode trap handler (vectored for interrupts when stvec.MODE = 1).
def trap(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +cause: U32, +tval: U32) -> Hart:
  Csr{+priv, +st, ie, ip, +tvec, scr, epc, ca, tv, +satp, cen, env} = s
  +st2 = U32.or(U32.and(st, 4294967005), U32.or(U32.shln(priv, 8n), U32.shln(U32.and(st, 2), 4n)))
  +base = U32.and(tvec, 4294967292)
  +vec = sel(Bool.and(isneg(cause), U32.is_eq(U32.and(tvec, 3), 1)), U32.add(base, U32.shln(U32.and(cause, 31), 2n)), base)
  Hart{True{}, vec, n, md.of(1, st2, satp), 1, fp, x, m, Csr{1, st2, ie, ip, tvec, scr, pc, cause, tval, satp, cen, env}, d, t}

def illegal(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  trap(pc, n, md, fv, fp, x, m, s, d, t, 2, inst)

# Writes rd (x0 stays 0) and moves to the next instruction.
def wr(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +v: U32) -> Hart:
  x[rd] <- v
  x[0] <- 0
  Hart{True{}, U32.add(pc, 4), n, md, fv, fp, x, m, s, d, t}

# The same, but ends the slice, so the slice loop re-reads interrupts.
def wr.stop(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +v: U32) -> Hart:
  x[rd] <- v
  x[0] <- 0
  Hart{False{}, U32.add(pc, 4), n, md, fv, fp, x, m, s, d, t}

def nxt(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Hart{True{}, U32.add(pc, 4), n, md, fv, fp, x, m, s, d, t}

def nxt.stop(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Hart{False{}, U32.add(pc, 4), n, md, fv, fp, x, m, s, d, t}

def jmp.go(+ok: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +to: U32) -> Hart:
  match ok:
    case True{}:
      x[rd] <- U32.add(pc, 4)
      x[0] <- 0
      Hart{True{}, to, n, md, fv, fp, x, m, s, d, t}
    case False{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 0, to)

# Jumps to `to`, linking into rd (rd = 0 links nowhere).
def jmp(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +to: U32) -> Hart:
  jmp.go(U32.is_zero(U32.and(to, 3)), pc, n, md, fv, fp, x, m, s, d, t, rd, to)

# MMU
# ---

def tlb.clr(k: Nat, t: Array<U32>, +i: U32) -> Array<U32>:
  match k:
    case 0n:
      t
    case 1n+p:
      t[i] <- 0
      tlb.clr(p, t, U32.add(i, 2))

def tlb.flush(t: Array<U32>) -> Array<U32>:
  tlb.clr(256n, t, 0)

# f: PTE flags; kind 0 load, 1 store, 2 fetch; md as in Hart.
def perm(+f: U32, +kind: U32, +md: U32) -> Bool:
  +u = nz(U32.and(f, 16))
  +pv = sel(nz(U32.and(md, 1)), bit(Bool.or(Bool.not(u), Bool.and(U32.is_ne(kind, 2), nz(U32.and(md, 2))))), bit(u))
  +rx = Bool.or(nz(U32.and(f, 2)), Bool.and(nz(U32.and(md, 4)), nz(U32.and(f, 8))))
  +ok = sel(U32.is_eq(kind, 0), bit(rx), sel(U32.is_eq(kind, 1), bit(nz(U32.and(f, 4))), bit(nz(U32.and(f, 8)))))
  nz(U32.and(pv, ok))

# 0: invalid, 1: leaf, 2: pointer to the next level
def pte.cls(+p: U32) -> U32:
  sel(Bool.or(U32.is_zero(U32.and(p, 1)), U32.is_eq(U32.and(p, 6), 4)), 0, sel(nz(U32.and(p, 10)), 1, 2))

# A leaf passed its checks: set A (and D on a store), fill the TLB.
def walk.fill(+ok: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +kind: U32, +va: U32, +a: U32, +pte: U32, +pg: U32) -> Wk:
  match ok:
    case False{}:
      Wk{m, s, t, 1}
    case True{}:
      +np = U32.or(pte, sel(U32.is_eq(kind, 1), 192, 64))
      m[U32.shrn(a, 2n)] <- np
      +i = U32.shln(U32.and(U32.shrn(va, 12n), 255), 1n)
      t[i] <- U32.or(U32.and(va, 4294963200), 1)
      t[U32.add(i, 1)] <- U32.or(pg, U32.and(np, 255))
      Wk{m, s, t, pg}

def walk.leaf(+bad: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +a: U32, +pte: U32, +pg: U32) -> Wk:
  match bad:
    case True{}:
      Wk{m, s, t, 1}
    case False{}:
      walk.fill(perm(pte, kind, md), m, s, t, kind, va, a, pte, pg)

def walk.l0k(+c: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +a: U32, +pte: U32) -> Wk:
  match c:
    case 1:
      walk.leaf(False{}, m, s, t, md, kind, va, a, pte, U32.shln(U32.shrn(pte, 10n), 12n))
    case _:
      Wk{m, s, t, 1}

def walk.l0(s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +a: U32, mp: Array<U32> & U32) -> Wk:
  (m, +pte) = mp
  walk.l0k(pte.cls(pte), m, s, t, md, kind, va, a, pte)

def walk.l1k(+c: U32, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +a: U32, +pte: U32) -> Wk:
  match c:
    case 0:
      Wk{m, s, t, 1}
    case 1:
      +pg = U32.or(U32.shln(U32.shrn(pte, 20n), 22n), U32.and(va, 4190208))
      walk.leaf(nz(U32.and(U32.shrn(pte, 10n), 1023)), m, s, t, md, kind, va, a, pte, pg)
    case _:
      +a0 = U32.add(U32.shln(U32.shrn(pte, 10n), 12n), U32.shln(U32.and(U32.shrn(va, 12n), 1023), 2n))
      walk.l0(s, t, md, kind, va, a0, Array.get(U32, m, U32.shrn(a0, 2n)))

def walk.l1(s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +a: U32, mp: Array<U32> & U32) -> Wk:
  (m, +pte) = mp
  walk.l1k(pte.cls(pte), m, s, t, md, kind, va, a, pte)

# The Sv32 page walk.
def walk(m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32) -> Wk:
  Csr{pr, st, ie, ip, tv, sc, ep, ca, tl, +sa, ce, en} = s
  +a1 = U32.add(U32.shln(U32.and(sa, 4194303), 12n), U32.shln(U32.shrn(va, 22n), 2n))
  walk.l1(Csr{pr, st, ie, ip, tv, sc, ep, ca, tl, sa, ce, en}, t, md, kind, va, a1, Array.get(U32, m, U32.shrn(a1, 2n)))

def xl.h(+hit: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32, +dat: U32) -> Wk:
  match hit:
    case True{}:
      Wk{m, s, t, U32.and(dat, 4294963200)}
    case False{}:
      walk(m, s, t, md, kind, va)

def xl.t(m: Array<U32>, s: Csr, r: R2, +md: U32, +kind: U32, +va: U32) -> Wk:
  R2{t, tag, +dat} = r
  +ok = Bool.and(perm(dat, kind, md), Bool.or(U32.is_ne(kind, 1), nz(U32.and(dat, 128))))
  xl.h(Bool.and(U32.is_eq(tag, U32.or(U32.and(va, 4294963200), 1)), ok), m, s, t, md, kind, va, dat)

def xl.b(+on: Bool, m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32) -> Wk:
  match on:
    case False{}:
      Wk{m, s, t, U32.and(va, 4294963200)}
    case True{}:
      +i = U32.shln(U32.and(U32.shrn(va, 12n), 255), 1n)
      xl.t(m, s, get2(t, i, U32.add(i, 1)), md, kind, va)

# Translates va for an access of `kind`; the TLB first, then the walk.
def xl(m: Array<U32>, s: Csr, t: Array<U32>, +md: U32, +kind: U32, +va: U32) -> Wk:
  xl.b(nz(U32.and(md, 8)), m, s, t, md, kind, va)

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

# (ier, rx available, thre)
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

def ld.ext(+f3: U32, +v: U32) -> U32:
  match f3:
    case 0:
      sext8(v)
    case 1:
      sext16(v)
    case 4:
      U32.and(v, 255)
    case 5:
      U32.and(v, 65535)
    case _:
      v

def ld.r(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +pa: U32) -> Hart:
  (m, w) = mw
  wr(pc, n, md, fv, fp, x, m, s, d, t, rd, ld.ext(f3, U32.shrn(w, U32.to_nat(U32.shln(U32.and(pa, 3), 3n)))))

def ld.io.ok(+ok: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +v: U32, +va: U32) -> Hart:
  match ok:
    case True{}:
      wr.stop(pc, n, md, fv, fp, x, m, s, d, t, rd, ld.ext(f3, v))
    case False{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 5, va)

def ld.io(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>, +rd: U32, +f3: U32, +va: U32) -> Hart:
  R2{d, v, ok} = r
  ld.io.ok(nz(ok), pc, n, md, fv, fp, x, m, s, d, t, rd, f3, v, va)

def ld.p(+ram: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +va: U32, +pa: U32) -> Hart:
  match ram:
    case True{}:
      ld.r(pc, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, rd, f3, pa)
    case False{}:
      ld.io(pc, n, md, fv, fp, x, m, s, io.rd(pa, d), t, rd, f3, va)

def ld.f(+fault: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +va: U32, +pa: U32) -> Hart:
  match fault:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 13, va)
    case False{}:
      ld.p(U32.is_lt(pa, RAM()), pc, n, md, fv, fp, x, m, s, d, t, rd, f3, va, pa)

def ld.w(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +rd: U32, +f3: U32, +va: U32) -> Hart:
  Wk{m, s, t, +r} = w
  ld.f(nz(U32.and(r, 1)), pc, n, md, fv, fp, x, m, s, d, t, rd, f3, va, U32.or(r, U32.and(va, 4095)))

def ld.b(+mis: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +f3: U32, +va: U32) -> Hart:
  match mis:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 4, va)
    case False{}:
      ld.w(pc, n, md, fv, fp, x, xl(m, s, t, md, 0, va), d, rd, f3, va)

def ld.a(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  (x, base) = xr
  +va = U32.add(base, F.immI(inst))
  +f3 = F.f3(inst)
  +mask = U32.sub(U32.shln(1, U32.to_nat(U32.and(f3, 3))), 1)
  ld.b(nz(U32.and(va, mask)), pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), f3, va)

def i.ld(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  ld.a(pc, n, md, fv, fp, Array.get(U32, x, F.rs1(inst)), m, s, d, t, inst)

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

def st.rmw(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +pa: U32, +v: U32) -> Hart:
  (m, w) = mw
  m[U32.shrn(pa, 2n)] <- st.merge(f3, pa, w, v)
  nxt(pc, n, md, fv, fp, x, m, s, d, t)

def st.io.ok(+ok: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +va: U32) -> Hart:
  match ok:
    case True{}:
      nxt.stop(pc, n, md, fv, fp, x, m, s, d, t)
    case False{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 7, va)

def st.io(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>, +va: U32) -> Hart:
  R2{d, v, ok} = r
  st.io.ok(nz(ok), pc, n, md, fv, fp, x, m, s, d, t, va)

def st.p(+ram: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +va: U32, +pa: U32, +v: U32) -> Hart:
  match ram:
    case True{}:
      st.rmw(pc, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, f3, pa, v)
    case False{}:
      st.io(pc, n, md, fv, fp, x, m, s, io.wr(pa, st.merge(f3, 0, 0, v), d), t, va)

def st.f(+fault: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +va: U32, +pa: U32, +v: U32) -> Hart:
  match fault:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 15, va)
    case False{}:
      st.p(U32.is_lt(pa, RAM()), pc, n, md, fv, fp, x, m, s, d, t, f3, va, pa, v)

def st.w(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +f3: U32, +va: U32, +v: U32) -> Hart:
  Wk{m, s, t, +r} = w
  st.f(nz(U32.and(r, 1)), pc, n, md, fv, fp, x, m, s, d, t, f3, va, U32.or(r, U32.and(va, 4095)), v)

def st.b(+mis: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +f3: U32, +va: U32, +v: U32) -> Hart:
  match mis:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 6, va)
    case False{}:
      st.w(pc, n, md, fv, fp, x, xl(m, s, t, md, 1, va), d, f3, va, v)

def st.a(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, base, v} = r
  +va = U32.add(base, F.immS(inst))
  +f3 = F.f3(inst)
  +mask = U32.sub(U32.shln(1, U32.to_nat(U32.and(f3, 3))), 1)
  st.b(nz(U32.and(va, mask)), pc, n, md, fv, fp, x, m, s, d, t, f3, va, v)

def i.st(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  st.a(pc, n, md, fv, fp, get2(x, F.rs1(inst), F.rs2(inst)), m, s, d, t, inst)

# Atomics (single owner of RAM: an AMO is a plain read-modify-write)
# ------------------------------------------------------------------

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

def amo.sc.go(+ok: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +v: U32) -> Hart:
  match ok:
    case True{}:
      m[U32.shrn(pa, 2n)] <- v
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, 0)
    case False{}:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, 1)

def amo.sc.k(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dr: Array<U32> & U32, t: Array<U32>, +rd: U32, +pa: U32, +v: U32) -> Hart:
  (d, rv) = dr
  d[D.RESV()] <- 0
  amo.sc.go(U32.is_eq(rv, U32.or(pa, 1)), pc, n, md, fv, fp, x, m, s, d, t, rd, pa, v)

def amo.k(+f5: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mw: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +pa: U32, +v: U32) -> Hart:
  match f5:
    case 2:
      (m, w) = mw
      d[D.RESV()] <- U32.or(pa, 1)
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, w)
    case 3:
      (m, w) = mw
      amo.sc.k(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.RESV()), t, rd, pa, v)
    case _:
      (m, +w) = mw
      m[U32.shrn(pa, 2n)] <- amo.f(f5, w, v)
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, w)

def amo.p(+ram: Bool, +f5: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +va: U32, +pa: U32, +v: U32) -> Hart:
  match ram:
    case True{}:
      amo.k(f5, pc, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(pa, 2n)), s, d, t, rd, pa, v)
    case False{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 5, 7), va)

def amo.f2(+fault: Bool, +f5: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +va: U32, +pa: U32, +v: U32) -> Hart:
  match fault:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 13, 15), va)
    case False{}:
      amo.p(U32.is_lt(pa, RAM()), f5, pc, n, md, fv, fp, x, m, s, d, t, rd, va, pa, v)

def amo.w(+f5: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>, +rd: U32, +va: U32, +v: U32) -> Hart:
  Wk{m, s, t, +r} = w
  amo.f2(nz(U32.and(r, 1)), f5, pc, n, md, fv, fp, x, m, s, d, t, rd, va, U32.or(r, U32.and(va, 4095)), v)

def amo.b(+mis: Bool, +f5: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +va: U32, +v: U32) -> Hart:
  match mis:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_eq(f5, 2), 4, 6), va)
    case False{}:
      amo.w(f5, pc, n, md, fv, fp, x, xl(m, s, t, md, sel(U32.is_eq(f5, 2), 0, 1), va), d, rd, va, v)

def amo.a(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, +va, v} = r
  amo.b(nz(U32.and(va, 3)), U32.shrn(inst, 27n), pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), va, v)

def i.amo.go(+ok: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match ok:
    case True{}:
      amo.a(pc, n, md, fv, fp, get2(x, F.rs1(inst), F.rs2(inst)), m, s, d, t, inst)
    case False{}:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)

def i.amo(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.amo.go(U32.is_eq(F.f3(inst), 2), pc, n, md, fv, fp, x, m, s, d, t, inst)

# Integer ops
# -----------

def op.v(+key: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +a: U32, +b: U32, +inst: U32) -> Hart:
  match key:
    case 0:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.add(a, b))
    case 256:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.sub(a, b))
    case 1:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.shln(a, shamt(b)))
    case 2:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, bit(slt(a, b)))
    case 3:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, bit(U32.is_lt(a, b)))
    case 4:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.xor(a, b))
    case 5:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.shrn(a, shamt(b)))
    case 261:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, sra(a, shamt(b)))
    case 6:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.or(a, b))
    case 7:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.and(a, b))
    case 8:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.mul(a, b))
    case 9:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, mulh(a, b))
    case 10:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, mulhsu(a, b))
    case 11:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, mulhu(a, b))
    case 12:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, div(a, b))
    case 13:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, divu(a, b))
    case 14:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, rem(a, b))
    case 15:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, remu(a, b))
    case _:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)

def i.op.k(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, a, b} = r
  op.v(U32.or(U32.shln(U32.shrn(inst, 25n), 3n), F.f3(inst)), pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), a, b, inst)

def i.op(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.op.k(pc, n, md, fv, fp, get2(x, F.rs1(inst), F.rs2(inst)), m, s, d, t, inst)

def opi.v(+f3: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +a: U32, +inst: U32) -> Hart:
  match f3:
    case 0:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.add(a, F.immI(inst)))
    case 1:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.shln(a, shamt(U32.shrn(inst, 20n))))
    case 2:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, bit(slt(a, F.immI(inst))))
    case 3:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, bit(U32.is_lt(a, F.immI(inst))))
    case 4:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.xor(a, F.immI(inst)))
    case 5:
      +k = shamt(U32.shrn(inst, 20n))
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, sel(nz(U32.and(inst, 1073741824)), sra(a, k), U32.shrn(a, k)))
    case 6:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.or(a, F.immI(inst)))
    case _:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, U32.and(a, F.immI(inst)))

def i.opi.k(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  (x, a) = xr
  opi.v(F.f3(inst), pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), a, inst)

def i.opi(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.opi.k(pc, n, md, fv, fp, Array.get(U32, x, F.rs1(inst)), m, s, d, t, inst)

# Jumps and branches
# ------------------

def br.t(+tk: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match tk:
    case True{}:
      jmp(pc, n, md, fv, fp, x, m, s, d, t, 0, U32.add(pc, F.immB(inst)))
    case False{}:
      nxt(pc, n, md, fv, fp, x, m, s, d, t)

def br.v(+f3: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a: U32, +b: U32, +inst: U32) -> Hart:
  match f3:
    case 0:
      br.t(U32.is_eq(a, b), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 1:
      br.t(U32.is_ne(a, b), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 4:
      br.t(slt(a, b), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 5:
      br.t(Bool.not(slt(a, b)), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 6:
      br.t(U32.is_lt(a, b), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 7:
      br.t(U32.is_ge(a, b), pc, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)

def i.br.k(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R2, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  R2{x, a, b} = r
  br.v(F.f3(inst), pc, n, md, fv, fp, x, m, s, d, t, a, b, inst)

def i.br(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.br.k(pc, n, md, fv, fp, get2(x, F.rs1(inst), F.rs2(inst)), m, s, d, t, inst)

def i.jalr.k(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  (x, a) = xr
  jmp(pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.and(U32.add(a, F.immI(inst)), 4294967294))

def i.jalr(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.jalr.k(pc, n, md, fv, fp, Array.get(U32, x, F.rs1(inst)), m, s, d, t, inst)

# CSRs
# ----

def csr.ok(+num: U32) -> Bool:
  match num:
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
    case 3200:
      True{}
    case 3201:
      True{}
    case 3202:
      True{}
    case _:
      False{}

# Counters read the instruction count, which is also time (one tick per
# instruction), and are readable from U-mode regardless of scounteren.
def csr.val(+num: U32, +st: U32, +ie: U32, +ip: U32, +tvec: U32, +scr: U32, +epc: U32, +cause: U32, +tval: U32, +satp: U32, +cen: U32, +env: U32, +n: U32, +nh: U32, +stip: U32, +seip: U32) -> U32:
  match num:
    case 256:
      st
    case 260:
      ie
    case 261:
      tvec
    case 262:
      cen
    case 266:
      env
    case 320:
      scr
    case 321:
      epc
    case 322:
      cause
    case 323:
      tval
    case 324:
      U32.or(ip, U32.or(U32.shln(stip, 5n), U32.shln(seip, 9n)))
    case 384:
      satp
    case 3072:
      n
    case 3073:
      n
    case 3074:
      n
    case _:
      nh

# The CSR file after writing v to num (num already validated).
def csr.put(+num: U32, +v: U32, +pr: U32, +st: U32, +ie: U32, +ip: U32, +tvec: U32, +scr: U32, +epc: U32, +cause: U32, +tval: U32, +satp: U32, +cen: U32, +env: U32) -> Csr:
  match num:
    case 256:
      Csr{pr, U32.or(U32.and(st, 4294180573), U32.and(v, 786722)), ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}
    case 260:
      Csr{pr, st, U32.and(v, 546), ip, tvec, scr, epc, cause, tval, satp, cen, env}
    case 261:
      Csr{pr, st, ie, ip, U32.and(v, 4294967293), scr, epc, cause, tval, satp, cen, env}
    case 262:
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, v, env}
    case 266:
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, v}
    case 320:
      Csr{pr, st, ie, ip, tvec, v, epc, cause, tval, satp, cen, env}
    case 321:
      Csr{pr, st, ie, ip, tvec, scr, U32.and(v, 4294967292), cause, tval, satp, cen, env}
    case 322:
      Csr{pr, st, ie, ip, tvec, scr, epc, v, tval, satp, cen, env}
    case 323:
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, v, satp, cen, env}
    case 324:
      Csr{pr, st, ie, U32.or(U32.and(ip, 4294967293), U32.and(v, 2)), tvec, scr, epc, cause, tval, satp, cen, env}
    case 384:
      # no ASID bits: Linux then runs without ASIDs
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, U32.and(v, 2151677951), cen, env}
    case _:
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}

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

# Any CSR write ends the slice and drops the fetch page; a satp write also
# flushes the TLB.
def csr.fin(+sp: Bool, +pc: U32, +n: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +old: U32) -> Hart:
  Csr{+pr, +st, ie, ip, tvec, scr, epc, cause, tval, +satp, cen, env} = s
  wr.stop(pc, n, md.of(pr, st, satp), 1, fp, x, m, Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}, d, csr.tlb(sp, t), rd, old)

def csr.go(+ok: Bool, +write: Bool, +num: U32, +old: U32, +src: U32, +op: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +rd: U32, +inst: U32) -> Hart:
  match ok write:
    case False{} _:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case True{} False{}:
      wr(pc, n, md, fv, fp, x, m, s, d, t, rd, old)
    case True{} True{}:
      Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env} = s
      csr.fin(U32.is_eq(num, 384), pc, n, fv, fp, x, m, csr.put(num, csr.new(op, old, src), pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env), d, t, rd, old)

def csr.c(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>, +src: U32, +inst: U32) -> Hart:
  Csr{+pr, +st, +ie, +ip, +tvec, +scr, +epc, +cause, +tval, +satp, +cen, +env} = s
  R3{d, nh, stip, seip} = r
  +num = U32.shrn(inst, 20n)
  +op = U32.and(F.f3(inst), 3)
  +write = Bool.or(U32.is_eq(op, 1), nz(F.rs1(inst)))
  +ok = Bool.and(csr.ok(num), Bool.and(U32.is_le(U32.and(U32.shrn(num, 8n), 3), pr), Bool.or(Bool.not(write), U32.is_ne(U32.shrn(num, 10n), 3))))
  +old = csr.val(num, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env, n, nh, stip, seip)
  csr.go(ok, write, num, old, src, op, pc, n, md, fv, fp, x, m, Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}, d, t, F.rd(inst), inst)

def csr.b(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  (x, rv) = xr
  +src = sel(nz(U32.and(inst, 16384)), F.rs1(inst), rv)
  csr.c(pc, n, md, fv, fp, x, m, s, get3(d, D.NH(), D.STIP(), D.SEIP()), t, src, inst)

def i.csr(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  csr.b(pc, n, md, fv, fp, Array.get(U32, x, F.rs1(inst)), m, s, d, t, inst)

# SBI: the firmware interface, answered by the emulator
# -----------------------------------------------------

def sbi.ret(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +err: U32, +val: U32) -> Hart:
  x[10] <- err
  x[11] <- val
  Hart{False{}, U32.add(pc, 4), n, md, fv, fp, x, m, s, d, t}

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

def sbi.base(+fid: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0: U32) -> Hart:
  match fid:
    case 0:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 16777216)
    case 1:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 87)
    case 2:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 1)
    case 3:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, sbi.probe(a0))
    case _:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 0)

# Arms the timer at (hi, lo); STIP clears until time reaches it again.
def sbi.timer(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dr: Array<U32> & U32, t: Array<U32>, +lo: U32, +hi: U32) -> Hart:
  (d, nh) = dr
  d[D.CL()] <- lo
  d[D.CH()] <- hi
  d[D.STIP()] <- bit(ge64(nh, n, hi, lo))
  sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 0)

def sbi.getc.k(+empty: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>) -> Hart:
  R2{d, v, ok} = r
  sbi.ret(pc, n, md, fv, fp, x, m, s, dev.upd(d), t, sel(empty, 4294967295, v), 0)

def sbi.getc(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R2, t: Array<U32>) -> Hart:
  R2{d, +h, +tl} = r
  sbi.getc.k(U32.is_eq(h, tl), pc, n, md, fv, fp, x, m, s, rx.pop(R2{d, h, tl}), t)

# Single hart: an IPI or remote fence that targets hart 0 acts locally.
def sbi.self(+mask: U32, +base: U32) -> Bool:
  Bool.or(U32.is_eq(base, 4294967295), Bool.and(U32.is_zero(base), nz(U32.and(mask, 1))))

def sbi.ipi(+hit: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Csr{pr, st, ie, +ip, tvec, scr, epc, cause, tval, satp, cen, env} = s
  sbi.ret(pc, n, md, fv, fp, x, m, Csr{pr, st, ie, sel(hit, U32.or(ip, 2), ip), tvec, scr, epc, cause, tval, satp, cen, env}, d, t, 0, 0)

def sbi.hsm(+fid: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0: U32) -> Hart:
  match fid:
    case 0:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0), 4294967290, 4294967293), 0)
    case 2:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0), 0, 4294967293), 0)
    case _:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 4294967294, 0)

def sbi.halt(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +code: U32) -> Hart:
  d[D.EXIT()] <- code
  sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 0, 0)

def sbi.k(+eid: U32, +fid: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +a0: U32, +a1: U32) -> Hart:
  match eid:
    case 16:
      sbi.base(fid, pc, n, md, fv, fp, x, m, s, d, t, a0)
    case 1414090053:
      sbi.timer(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t, a0, a1)
    case 0:
      sbi.timer(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t, a0, a1)
    case 1:
      sbi.ret(pc, n, md, fv, fp, x, m, s, tx.push(d, a0), t, 0, 0)
    case 2:
      sbi.getc(pc, n, md, fv, fp, x, m, s, get2(d, U.RXH(), U.RXT()), t)
    case 8:
      sbi.halt(pc, n, md, fv, fp, x, m, s, d, t, 1)
    case 7557193:
      sbi.ipi(sbi.self(a0, a1), pc, n, md, fv, fp, x, m, s, d, t)
    case 1380339267:
      sbi.ret(pc, n, md, 1, fp, x, m, s, d, tlb.flush(t), 0, 0)
    case 4739917:
      sbi.hsm(fid, pc, n, md, fv, fp, x, m, s, d, t, a0)
    case 1397904212:
      sbi.halt(pc, n, md, fv, fp, x, m, s, d, t, sel(U32.is_zero(a0), 1, 3))
    case _:
      sbi.ret(pc, n, md, fv, fp, x, m, s, d, t, 4294967294, 0)

def sbi.b(+eid: U32, +fid: U32, +a0: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, xr: Array<U32> & U32, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  (x, a1) = xr
  sbi.k(eid, fid, pc, n, md, fv, fp, x, m, s, d, t, a0, a1)

def sbi.a(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, r: R3, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  R3{x, eid, fid, a0} = r
  sbi.b(eid, fid, a0, pc, n, md, fv, fp, Array.get(U32, x, 11), m, s, d, t)

def sbi(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  sbi.a(pc, n, md, fv, fp, get3(x, 17, 16, 10), m, s, d, t)

# Privileged instructions
# -----------------------

def i.sret(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  Csr{pr, +st, ie, ip, tvec, scr, +epc, cause, tval, +satp, cen, env} = s
  +np = U32.and(U32.shrn(st, 8n), 1)
  +st2 = U32.or(U32.and(st, 4294967005), U32.or(32, U32.and(U32.shrn(st, 4n), 2)))
  Hart{False{}, epc, n, md.of(np, st2, satp), 1, fp, x, m, Csr{np, st2, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}, d, t}

def i.wfi(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  d[D.WFI()] <- 1
  nxt.stop(pc, n, md, fv, fp, x, m, s, d, t)

def i.sfence(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  nxt(pc, n, md, 1, fp, x, m, s, d, tlb.flush(t))

def i.ecall(+user: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match user:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 8, 0)
    case False{}:
      sbi(pc, n, md, fv, fp, x, m, s, d, t)

def i.sup.k(+which: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match which:
    case 0:
      i.sret(pc, n, md, fv, fp, x, m, s, d, t)
    case 1:
      i.wfi(pc, n, md, fv, fp, x, m, s, d, t)
    case _:
      i.sfence(pc, n, md, fv, fp, x, m, s, d, t)

def i.sup(+bad: Bool, +which: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match bad:
    case True{}:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case False{}:
      i.sup.k(which, pc, n, md, fv, fp, x, m, s, d, t)

def i.priv.k(+inst: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +user: Bool) -> Hart:
  match inst:
    case 115:
      i.ecall(user, pc, n, md, fv, fp, x, m, s, d, t)
    case 1048691:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 3, pc)
    case 270532723:
      i.sup(user, 0, pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 273678451:
      i.sup(user, 1, pc, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      i.sup(Bool.or(user, U32.is_ne(U32.shrn(inst, 25n), 9)), 2, pc, n, md, fv, fp, x, m, s, d, t, inst)

# S-mode-only instructions: 0 sret, 1 wfi, 2 sfence.vma
def i.sys.k(+f3: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  match f3:
    case 0:
      i.priv.k(inst, pc, n, md, fv, fp, x, m, s, d, t, U32.is_zero(U32.and(md, 1)))
    case 4:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case _:
      i.csr(pc, n, md, fv, fp, x, m, s, d, t, inst)

def i.sys(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +inst: U32) -> Hart:
  i.sys.k(F.f3(inst), pc, n, md, fv, fp, x, m, s, d, t, inst)

# Decode and execute
# ------------------

def exec.op(+op: U32, +inst: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match op:
    case 19:
      i.opi(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 51:
      i.op(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 3:
      i.ld(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 35:
      i.st(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 99:
      i.br(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 55:
      wr(pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.and(inst, 4294963200))
    case 23:
      wr(pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.add(pc, U32.and(inst, 4294963200)))
    case 111:
      jmp(pc, n, md, fv, fp, x, m, s, d, t, F.rd(inst), U32.add(pc, F.immJ(inst)))
    case 103:
      i.jalr(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 115:
      i.sys(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 47:
      i.amo(pc, n, md, fv, fp, x, m, s, d, t, inst)
    case 15:
      # fence, fence.i: one owner, no decode cache, so nothing to order
      nxt(pc, n, md, fv, fp, x, m, s, d, t)
    case _:
      illegal(pc, n, md, fv, fp, x, m, s, d, t, inst)

def exec.i(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, mi: Array<U32> & U32, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  (m, +inst) = mi
  exec.op(U32.and(inst, 127), inst, pc, n, md, fv, fp, x, m, s, d, t)

def fetch.ok(+ram: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pg: U32) -> Hart:
  match ram:
    case True{}:
      exec.i(pc, n, md, U32.and(pc, 4294963200), pg, x, Array.get(U32, m, U32.shrn(U32.or(pg, U32.and(pc, 4095)), 2n)), s, d, t)
    case False{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 1, pc)

def fetch.f(+fault: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +r: U32) -> Hart:
  match fault:
    case True{}:
      trap(pc, n, md, fv, fp, x, m, s, d, t, 12, pc)
    case False{}:
      fetch.ok(U32.is_lt(r, RAM()), pc, n, md, fv, fp, x, m, s, d, t, r)

def fetch.w(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, w: Wk, d: Array<U32>) -> Hart:
  Wk{m, s, t, +r} = w
  fetch.f(nz(U32.and(r, 1)), pc, n, md, fv, fp, x, m, s, d, t, r)

def step.f(+hit: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  match hit:
    case True{}:
      exec.i(pc, n, md, fv, fp, x, Array.get(U32, m, U32.shrn(U32.or(fp, U32.and(pc, 4095)), 2n)), s, d, t)
    case False{}:
      fetch.w(pc, n, md, fv, fp, x, xl(m, s, t, md, 2, pc), d)

# One instruction.
def step(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>) -> Hart:
  step.f(U32.is_eq(U32.and(pc, 4294963200), fv), pc, U32.add(n, 1), md, fv, fp, x, m, s, d, t)

# Up to k instructions; stops early when an instruction ends the slice.
def run(k: Nat, h: Hart) -> Hart:
  match k h:
    case 0n _:
      h
    case 1n+p Hart{True{}, pc, n, md, fv, fp, x, m, s, d, t}:
      run(p, step(pc, n, md, fv, fp, x, m, s, d, t))
    case 1n+p Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}:
      Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}

# Slices
# ------
# A slice runs until the next timer deadline, the end of the epoch budget, or
# an instruction that may change which interrupt is next. Between slices the
# hart takes interrupts and sleeps through WFI by jumping time to the deadline:
# time is the instruction count, so an idle guest costs nothing to wait.

def slice.fin(+left: U32, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart:
  (d, ex) = de
  Hart{Bool.and(nz(left), U32.is_zero(ex)), pc, n, md, fv, fp, x, m, s, d, t}

def slice.post(+n0: U32, +nh: U32, +left: U32, h: Hart) -> Hart:
  Hart{go, pc, +n, md, fv, fp, x, m, s, d, t} = h
  +left2 = U32.sub(left, U32.sub(n, n0))
  d[D.LEFT()] <- left2
  d[D.NH()] <- U32.add(nh, bit(U32.is_lt(n, n0)))
  slice.fin(left2, pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

# Runs one slice of k = min(left, until the deadline, until n wraps) steps.
def slice.run(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32, +due: Bool, +left: U32) -> Hart:
  +dlo = U32.sub(cl, n)
  +dhi = U32.sub(U32.sub(ch, nh), bit(U32.is_lt(cl, n)))
  +k1 = sel(Bool.or(due, nz(dhi)), left, umin(left, dlo))
  +k = sel(U32.is_zero(n), k1, umin(k1, U32.sub(0, n)))
  slice.post(n, nh, left, run(U32.to_nat(k), Hart{True{}, pc, n, md, fv, fp, x, m, s, d, t}))

def slice.idle(+armed: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32) -> Hart:
  match armed:
    case True{}:
      d[D.NH()] <- ch
      Hart{True{}, pc, cl, md, fv, fp, x, m, s, d, t}
    case False{}:
      # asleep with nothing that could wake it: hand the hart to the host
      d[D.EXIT()] <- 2
      Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}

# irq: an enabled interrupt is pending; wake: one is pending at all
def slice.c(+irq: Bool, +wake: Bool, +wfi: Bool, +pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, d: Array<U32>, t: Array<U32>, +pend: U32, +nh: U32, +cl: U32, +ch: U32, +due: Bool, +left: U32) -> Hart:
  match irq wake wfi:
    case True{} _ _:
      d[D.WFI()] <- 0
      trap(pc, n, md, fv, fp, x, m, s, d, t, U32.or(2147483648, sel(nz(U32.and(pend, 512)), 9, sel(nz(U32.and(pend, 2)), 1, 5))), 0)
    case False{} True{} True{}:
      d[D.WFI()] <- 0
      Hart{True{}, pc, n, md, fv, fp, x, m, s, d, t}
    case False{} False{} True{}:
      slice.idle(Bool.and(Bool.not(due), Bool.not(Bool.and(U32.is_eq(cl, 4294967295), U32.is_eq(ch, 4294967295)))), pc, n, md, fv, fp, x, m, s, d, t, nh, cl, ch)
    case False{} _ False{}:
      slice.run(pc, n, md, fv, fp, x, m, s, d, t, nh, cl, ch, due, left)

def slice.b(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>, +nh: U32, +cl: U32, +ch: U32, +due: Bool) -> Hart:
  Csr{+pr, +st, +ie, +ip, tvec, scr, epc, cause, tval, satp, cen, env} = s
  R3{d, seip, wfi, left} = r
  +pend = U32.and(U32.or(ip, U32.or(U32.shln(bit(due), 5n), U32.shln(seip, 9n))), ie)
  +on = Bool.or(U32.is_zero(pr), nz(U32.and(st, 2)))
  slice.c(Bool.and(nz(pend), on), nz(pend), nz(wfi), pc, n, md, fv, fp, x, m, Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env}, d, t, pend, nh, cl, ch, due, left)

def slice.a(+pc: U32, +n: U32, +md: U32, +fv: U32, +fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: R3, t: Array<U32>) -> Hart:
  R3{d, +nh, +cl, +ch} = r
  +due = ge64(nh, n, ch, cl)
  d[D.STIP()] <- bit(due)
  slice.b(pc, n, md, fv, fp, x, m, s, get3(d, D.SEIP(), D.WFI(), D.LEFT()), t, nh, cl, ch, due)

def slice(h: Hart) -> Hart:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  slice.a(pc, n, md, fv, fp, x, m, s, get3(dev.upd(d), D.NH(), D.CL(), D.CH()), t)

# An epoch: slices until the budget in D.LEFT is spent or the host is needed
# (D.EXIT: 1 power off, 2 asleep for good, 3 reboot). k bounds the slices.
def epoch(k: Nat, h: Hart) -> Hart:
  match k h:
    case 0n _:
      h
    case 1n+p Hart{True{}, pc, n, md, fv, fp, x, m, s, d, t}:
      epoch(p, slice(Hart{True{}, pc, n, md, fv, fp, x, m, s, d, t}))
    case 1n+p Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}:
      Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}

# Host interface
# --------------

# A hart at reset: S-mode, MMU off, a0 = hart id, a1 = the device tree.
def Hart.new(m: Array<U32>, +hid: U32, +dtb: U32, +pc: U32) -> Hart:
  x = [0 : U32*32n]
  x[10] <- hid
  x[11] <- dtb
  d = [0 : U32*131072n]
  d[D.CL()] <- 4294967295
  d[D.CH()] <- 4294967295
  d[D.HART()] <- hid
  Hart{True{}, pc, 0, 1, 1, 1, x, m, Csr{1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, d, [0 : U32*512n]}

def arm.a(+budget: U32, pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart:
  (d, ex) = de
  d[D.LEFT()] <- budget
  Hart{U32.is_zero(ex), pc, n, md, fv, fp, x, m, s, d, t}

# Gives the hart a budget of instructions for the next epoch (a hart that
# has powered off stays parked).
def Hart.arm(+budget: U32, h: Hart) -> Hart:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  arm.a(budget, pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

def drain.go(k: Nat, dv: Array<U32> & U32, +i: U32, acc: List<&2, U32>) -> Array<U32> & List<&2, U32>:
  match k:
    case 0n:
      (d, v) = dv
      (d, acc)
    case 1n+p:
      (d, v) = dv
      drain.go(p, Array.get(U32, d, U32.sub(i, 1)), U32.sub(i, 1), v <> acc)

def drain.fin(pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, r: Array<U32> & List<&2, U32>, t: Array<U32>) -> Hart & List<&2, U32>:
  (d, bs) = r
  d[U.TXN()] <- 0
  (Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}, bs)

def drain.a(pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dk: Array<U32> & U32, t: Array<U32>) -> Hart & List<&2, U32>:
  (d, +k) = dk
  +e = U32.add(U.TX(), U32.sub(k, 1))
  drain.fin(pc, n, md, fv, fp, x, m, s, drain.go(U32.to_nat(k), Array.get(U32, d, e), e, Nil{}), t)

# Takes the bytes the guest wrote to the console since the last drain.
def Hart.drain(h: Hart) -> Hart & List<&2, U32>:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  drain.a(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, U.TXN()), t)

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
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  Hart{go, pc, n, md, fv, fp, x, m, s, dev.upd(feed.go(bs, d)), t}

def exit.a(pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart & U32:
  (d, e) = de
  (Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}, e)

# Why the last epoch ended early (0: it did not; see `epoch`).
def Hart.exit(h: Hart) -> Hart & U32:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  exit.a(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.EXIT()), t)

def count.a(pc: U32, +n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, dh: Array<U32> & U32, t: Array<U32>) -> Hart & (U32 & U32):
  (d, nh) = dh
  (Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}, (nh, n))

# Instructions retired so far, as (hi, lo).
def Hart.count(h: Hart) -> Hart & (U32 & U32):
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  count.a(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.NH()), t)


# Fleets
# ------
# Independent machines (each a hart with its own RAM) as a balanced binary
# tree. An epoch over the fleet is one fork tree that ends in the flat
# per-hart loops: called with `!`, one bang runs one machine per GPU lane.
# Lanes share nothing inside an epoch, so no lane ever waits on another.

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

def trace.line(+pc: U32, +n: U32, s: Csr) -> String:
  Csr{pr, st, ie, ip, tvec, scr, epc, cause, tval, satp, cen, env} = s
  "[trace] n=" ++ U32.show(n) ++ " pc=" ++ U32.show(pc) ++ " priv=" ++ U32.show(pr) ++ " scause=" ++ U32.show(cause) ++ " sepc=" ++ U32.show(epc) ++ " stval=" ++ U32.show(tval)

def trace.pick(on: Bool, +pc: U32, +n: U32, s: Csr) -> String:
  match on:
    case True{}:
      trace.line(pc, n, s)
    case False{}:
      ""

def trace.a(+on: Bool, +pc: U32, +n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, +s: Csr, d: Array<U32>, t: Array<U32>) -> Hart & String:
  (Hart{False{}, pc, n, md, fv, fp, x, m, s, d, t}, trace.pick(on, pc, n, s))

def trace.b(pc: U32, n: U32, md: U32, fv: U32, fp: U32, x: Array<U32>, m: Array<U32>, s: Csr, de: Array<U32> & U32, t: Array<U32>) -> Hart & String:
  (d, on) = de
  trace.a(nz(on), pc, n, md, fv, fp, x, m, s, d, t)

# The trace line for this epoch, or "" when tracing is off.
def Hart.trace(h: Hart) -> Hart & String:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  trace.b(pc, n, md, fv, fp, x, m, s, Array.get(U32, d, D.TRACE()), t)

def Hart.set_trace(+on: U32, h: Hart) -> Hart:
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t} = h
  d[D.TRACE()] <- on
  Hart{go, pc, n, md, fv, fp, x, m, s, d, t}
