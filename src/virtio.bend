import Base

# virtio-mmio devices for wiltee: a block device at 0xF5000000 (PLIC source
# 2) and a network device at 0xF5001000 (PLIC source 3). virtio 1.x over
# virtio-mmio version 2, split virtqueues only (no indirect descriptors, no
# event index). Every def is a total function of the guest RAM m and the
# machine's device words d; QueueNotify runs the requests to completion.
#
# Guest RAM is touched only through gw and sw (aligned words). Areas of d
# that hold bytes use "d byte addresses": byte b is byte (b & 3) of d[b >> 2].
#
# Device words (indices into d):
#   1024..1279   block: registers, queue 0, the GET_ID string
#   1280..1535   network: registers, queues 0 (receive) and 1 (transmit)
#   131072..     transmit buffer, guest -> host: 128 KiB of records
#                [len_lo, len_hi, frame...], back to back (what net.take hands out)
#   163840..     receive buffer, host -> guest: 128 KiB of records, each at
#                a word boundary: [len_lo, len_hi, 12-byte virtio_net_hdr_v1,
#                frame...], so header and frame keep the alignment Linux
#                gives its receive buffers (2 mod 4) and copy by words;
#                net.give first moves the records still waiting to the front
#   1048576..    the disk image, 4 bytes per word, little-endian
# Array indexes wrap, so d needs 2^18 words at least (2^20 plus the disk
# when a disk is attached), or these areas would land on other devices.
#
# Registers of the device at base b (1024 block, 1280 network):
#   b+0 Status, b+1 DeviceFeaturesSel, b+2 DriverFeaturesSel, b+3 and b+4
#   the driver's feature words 0 and 1, b+5 QueueSel, b+6 InterruptStatus.
#   Queue q lives at b+16+16q: +0 QueueNum, +1 QueueReady, +2/+3 desc,
#   +4/+5 driver (avail), +6/+7 device (used), +8 next avail index to read,
#   +9 next used index to write.
#   A reset (Status = 0) clears b+0..b+7 and the queues. These survive it:
#   block b+8 capacity in sectors (0: no disk); network b+8 the MAC's last
#   byte | 256 once set, b+11 bytes in the transmit buffer, b+12/b+13 head
#   and tail of the receive buffer (byte offsets).

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

def umin(+a: U32, +b: U32) -> U32:
  sel(U32.is_lt(a, b), a, b)

# a rounded up to a multiple of 4
def up4(+a: U32) -> U32:
  U32.and(U32.add(a, 3), 4294967292)

def wal(+a: U32) -> U32:
  U32.and(a, 4294967292)

# the bit offset of byte (a & 3) in its word
def sh8(+a: U32) -> Nat:
  U32.to_nat(U32.shln(U32.and(a, 3), 3n))

def byte.of(+a: U32, +w: U32) -> U32:
  U32.and(U32.shrn(w, sh8(a)), 255)

def byte.put(+a: U32, +w: U32, +b: U32) -> U32:
  U32.or(U32.and(w, U32.not(U32.shln(255, sh8(a)))), U32.shln(U32.and(b, 255), sh8(a)))

# Layout
# ------

def BLK() -> U32:
  1024

def NET() -> U32:
  1280

# block capacity in sectors
def CAP() -> U32:
  1032

# the GET_ID string (5 words)
def IDW() -> U32:
  1088

# network: MAC's last byte, transmit fill, receive head and tail
def MAC() -> U32:
  1288

def TXF() -> U32:
  1291

def RXH() -> U32:
  1292

def RXT() -> U32:
  1293

# the receive queue's registers
def RXQ() -> U32:
  1296

# d byte addresses of the frame buffers and the disk
def TXB() -> U32:
  524288

def RXB() -> U32:
  655360

def DISK() -> U32:
  4194304

# bytes in each frame buffer
def BUF() -> U32:
  131072

def QMAX() -> U32:
  256

def base(+dev: U32) -> U32:
  U32.add(1024, U32.shln(dev, 8n))

def qbase(+dev: U32, +q: U32) -> U32:
  U32.add(U32.add(base(dev), 16), U32.shln(q, 4n))

# queues per device: 1 block, 2 network
def nq(+dev: U32) -> U32:
  U32.add(U32.and(dev, 1), 1)

# Records
# -------

type VA is Type:
  VA{m: Array<U32>, d: Array<U32>, v: U32}

type MD is Type:
  MD{m: Array<U32>, d: Array<U32>}

type R2 is Type:
  R2{a: Array<U32>, u: U32, v: U32}

type R3 is Type:
  R3{a: Array<U32>, u: U32, v: U32, w: U32}

# a descriptor: address, length, flags | next << 16
type DS is Type:
  DS{m: Array<U32>, d: Array<U32>, a: U32, l: U32, f: U32}

# a chain's totals: readable bytes r, writable bytes w, the last writable
# byte sa (the block status) and the first readable buffer ha (the header)
type SM is Type:
  SM{m: Array<U32>, d: Array<U32>, r: U32, w: U32, sa: U32, ha: U32}

# a queue's registers
type Q is Data:
  Q{rdy: U32, num: U32, desc: U32, avail: U32, used: U32, last: U32, uidx: U32}

type DQ is Type:
  DQ{d: Array<U32>, q: Q}

# the receive loop: go = a frame and a buffer are both waiting
type RS is Type:
  RS{m: Array<U32>, d: Array<U32>, go: Bool, i: U32, u: U32, hd: U32, n: U32}

type DL is Type:
  DL{d: Array<U32>, fs: List<&2, U32>}

type GS is Type:
  GS{d: Array<U32>, fs: List<&2, U32>, tl: U32}

def get2.b(+u: U32, p: Array<U32> & U32) -> R2:
  (a, v) = p
  R2{a, u, v}

def get2.a(+j: U32, p: Array<U32> & U32) -> R2:
  (a, u) = p
  get2.b(u, Array.get(U32, a, j))

def get2(a: Array<U32>, +i: U32, +j: U32) -> R2:
  get2.a(j, Array.get(U32, a, i))

def va.k(m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, v) = p
  VA{m, d, v}

def va.md(r: MD) -> VA:
  MD{m, d} = r
  VA{m, d, 0}

# Guest memory
# ------------
# The only two defs that index m: guest-physical pa is byte (pa & 3) of
# m[pa >> 2]. Callers pass word-aligned addresses.

def gw(m: Array<U32>, +pa: U32) -> Array<U32> & U32:
  Array.get(U32, m, U32.shrn(pa, 2n))

def sw(m: Array<U32>, +pa: U32, +w: U32) -> Array<U32>:
  Array.set(U32, m, U32.shrn(pa, 2n), w)

def gb.k(+pa: U32, p: Array<U32> & U32) -> Array<U32> & U32:
  (m, +w) = p
  (m, byte.of(pa, w))

# a byte
def gb(m: Array<U32>, +pa: U32) -> Array<U32> & U32:
  gb.k(pa, gw(m, wal(pa)))

def sb.k(+pa: U32, +b: U32, p: Array<U32> & U32) -> Array<U32>:
  (m, +w) = p
  sw(m, wal(pa), byte.put(pa, w, b))

def sb(m: Array<U32>, +pa: U32, +b: U32) -> Array<U32>:
  sb.k(pa, b, gw(m, wal(pa)))

def gh.k(+pa: U32, p: Array<U32> & U32) -> Array<U32> & U32:
  (m, +w) = p
  (m, U32.and(U32.shrn(w, sh8(U32.and(pa, 2))), 65535))

# a 16-bit word (2-aligned)
def gh(m: Array<U32>, +pa: U32) -> Array<U32> & U32:
  gh.k(pa, gw(m, wal(pa)))

def shw.k(+pa: U32, +v: U32, p: Array<U32> & U32) -> Array<U32>:
  (m, +w) = p
  +s = sh8(U32.and(pa, 2))
  sw(m, wal(pa), U32.or(U32.and(w, U32.not(U32.shln(65535, s))), U32.shln(U32.and(v, 65535), s)))

def shw(m: Array<U32>, +pa: U32, +v: U32) -> Array<U32>:
  shw.k(pa, v, gw(m, wal(pa)))

def g3.c(+u: U32, +v: U32, p: Array<U32> & U32) -> R3:
  (m, w) = p
  R3{m, u, v, w}

def g3.b(+u: U32, +pc: U32, p: Array<U32> & U32) -> R3:
  (m, v) = p
  g3.c(u, v, gw(m, pc))

def g3.a(+pb: U32, +pc: U32, p: Array<U32> & U32) -> R3:
  (m, u) = p
  g3.b(u, pc, gw(m, pb))

# three guest words
def g3(m: Array<U32>, +pa: U32, +pb: U32, +pc: U32) -> R3:
  g3.a(pb, pc, gw(m, pa))

# Bytes of d
# ----------

def db.k(+b: U32, p: Array<U32> & U32) -> Array<U32> & U32:
  (d, +w) = p
  (d, byte.of(b, w))

def db(d: Array<U32>, +b: U32) -> Array<U32> & U32:
  db.k(b, Array.get(U32, d, U32.shrn(b, 2n)))

def dbs.k(+b: U32, +v: U32, p: Array<U32> & U32) -> Array<U32>:
  (d, +w) = p
  Array.set(U32, d, U32.shrn(b, 2n), byte.put(b, w, v))

def dbs(d: Array<U32>, +b: U32, +v: U32) -> Array<U32>:
  dbs.k(b, v, Array.get(U32, d, U32.shrn(b, 2n)))

# Copies
# ------
# Between guest addresses and d byte addresses. Each loop is one def: its
# argument q carries the read for the current step.

# d -> guest, k bytes; q = (d, the byte at s)
def cb.dm(k: Nat, m: Array<U32>, q: Array<U32> & U32, +ga: U32, +s: U32) -> MD:
  match k:
    case 0n:
      (d, b) = q
      MD{m, d}
    case 1n+p:
      (d, +b) = q
      cb.dm(p, sb(m, ga, b), db(d, U32.add(s, 1)), U32.add(ga, 1), U32.add(s, 1))

# d -> guest, k words; q = (d, d[i])
def cw.dm(k: Nat, m: Array<U32>, q: Array<U32> & U32, +ga: U32, +i: U32) -> MD:
  match k:
    case 0n:
      (d, w) = q
      MD{m, d}
    case 1n+p:
      (d, +w) = q
      cw.dm(p, sw(m, ga, w), Array.get(U32, d, U32.add(i, 1)), U32.add(ga, 4), U32.add(i, 1))

# guest -> d, k bytes; q = (m, the byte at ga)
def cb.md(k: Nat, q: Array<U32> & U32, d: Array<U32>, +ga: U32, +s: U32) -> MD:
  match k:
    case 0n:
      (m, b) = q
      MD{m, d}
    case 1n+p:
      (m, +b) = q
      cb.md(p, gb(m, U32.add(ga, 1)), dbs(d, s, b), U32.add(ga, 1), U32.add(s, 1))

# guest -> d, k words; q = (m, the word at ga)
def cw.md(k: Nat, q: Array<U32> & U32, d: Array<U32>, +ga: U32, +i: U32) -> MD:
  match k:
    case 0n:
      (m, w) = q
      MD{m, d}
    case 1n+p:
      (m, +w) = q
      cw.md(p, gw(m, U32.add(ga, 4)), Array.set(U32, d, i, w), U32.add(ga, 4), U32.add(i, 1))

# The leading bytes of an n-byte copy between a and s: up to a's word
# boundary when a and s share their alignment (words follow), else all.
def cp.head(+a: U32, +s: U32, +n: U32) -> U32:
  sel(U32.is_zero(U32.and(U32.xor(a, s), 3)), umin(U32.and(U32.sub(4, U32.and(a, 3)), 3), n), n)

def cp.dm.t(r: MD, +ga: U32, +s: U32, +t: U32) -> MD:
  MD{m, d} = r
  cb.dm(U32.to_nat(t), m, db(d, s), ga, s)

def cp.dm.w(r: MD, +ga: U32, +s: U32, +w: U32, +t: U32) -> MD:
  MD{m, d} = r
  +n4 = U32.shln(w, 2n)
  cp.dm.t(cw.dm(U32.to_nat(w), m, Array.get(U32, d, U32.shrn(s, 2n)), ga, U32.shrn(s, 2n)), U32.add(ga, n4), U32.add(s, n4), t)

# n bytes from d byte address s to guest address ga
def cp.dm(m: Array<U32>, d: Array<U32>, +ga: U32, +s: U32, +n: U32) -> MD:
  +h = cp.head(ga, s, n)
  +rest = U32.sub(n, h)
  cp.dm.w(cb.dm(U32.to_nat(h), m, db(d, s), ga, s), U32.add(ga, h), U32.add(s, h), U32.shrn(rest, 2n), U32.and(rest, 3))

def cp.md.t(r: MD, +ga: U32, +s: U32, +t: U32) -> MD:
  MD{m, d} = r
  cb.md(U32.to_nat(t), gb(m, ga), d, ga, s)

def cp.md.w(r: MD, +ga: U32, +s: U32, +w: U32, +t: U32) -> MD:
  MD{m, d} = r
  +n4 = U32.shln(w, 2n)
  cp.md.t(cw.md(U32.to_nat(w), gw(m, ga), d, ga, U32.shrn(s, 2n)), U32.add(ga, n4), U32.add(s, n4), t)

# n bytes from guest address ga to d byte address s
def cp.md(m: Array<U32>, d: Array<U32>, +ga: U32, +s: U32, +n: U32) -> MD:
  +h = cp.head(ga, s, n)
  +rest = U32.sub(n, h)
  cp.md.w(cb.md(U32.to_nat(h), gb(m, ga), d, ga, s), U32.add(ga, h), U32.add(s, h), U32.shrn(rest, 2n), U32.and(rest, 3))

# Virtqueues
# ----------

def ql.g(+rdy: U32, +num: U32, +desc: U32, +avail: U32, +used: U32, +last: U32, p: Array<U32> & U32) -> DQ:
  (d, +uidx) = p
  DQ{d, Q{rdy, num, desc, avail, used, last, uidx}}

def ql.f(+qb: U32, +rdy: U32, +num: U32, +desc: U32, +avail: U32, +used: U32, p: Array<U32> & U32) -> DQ:
  (d, +last) = p
  ql.g(rdy, num, desc, avail, used, last, Array.get(U32, d, U32.add(qb, 9)))

def ql.e(+qb: U32, +rdy: U32, +num: U32, +desc: U32, +avail: U32, p: Array<U32> & U32) -> DQ:
  (d, +used) = p
  ql.f(qb, rdy, num, desc, avail, used, Array.get(U32, d, U32.add(qb, 8)))

def ql.d(+qb: U32, +rdy: U32, +num: U32, +desc: U32, p: Array<U32> & U32) -> DQ:
  (d, +avail) = p
  ql.e(qb, rdy, num, desc, avail, Array.get(U32, d, U32.add(qb, 6)))

def ql.c(+qb: U32, +rdy: U32, +num: U32, p: Array<U32> & U32) -> DQ:
  (d, +desc) = p
  ql.d(qb, rdy, num, desc, Array.get(U32, d, U32.add(qb, 4)))

def ql.b(+qb: U32, +rdy: U32, p: Array<U32> & U32) -> DQ:
  (d, +num) = p
  ql.c(qb, rdy, num, Array.get(U32, d, U32.add(qb, 2)))

def ql.a(+qb: U32, p: Array<U32> & U32) -> DQ:
  (d, +rdy) = p
  ql.b(qb, rdy, Array.get(U32, d, qb))

# the registers of the queue at qb
def ql(d: Array<U32>, +qb: U32) -> DQ:
  ql.a(qb, Array.get(U32, d, U32.add(qb, 1)))

# usable: ready, with a size
def q.ok(+q: Q) -> Bool:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  Bool.and(nz(rdy), nz(num))

# the queue size as loop fuel (QueueNum is clamped to QMAX when written)
def qn(+q: Q) -> Nat:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  U32.to_nat(num)

def ds.c(d: Array<U32>, +a: U32, +l: U32, p: Array<U32> & U32) -> DS:
  (m, f) = p
  DS{m, d, a, l, f}

def ds.b(d: Array<U32>, +a: U32, +e: U32, p: Array<U32> & U32) -> DS:
  (m, l) = p
  ds.c(d, a, l, gw(m, U32.add(e, 12)))

def ds.a(d: Array<U32>, +e: U32, p: Array<U32> & U32) -> DS:
  (m, a) = p
  ds.b(d, a, e, gw(m, U32.add(e, 8)))

# descriptor i (the high address word is ignored: RAM sits below 4 GiB)
def ds.rd(m: Array<U32>, d: Array<U32>, +q: Q, +i: U32) -> DS:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  +e = U32.add(desc, U32.shln(U32.and(i, U32.sub(num, 1)), 4n))
  ds.a(d, e, gw(m, e))

def ds.next(r: MD, +q: Q, +i: U32) -> DS:
  MD{m, d} = r
  ds.rd(m, d, q, i)

# Totals of the chain at s, following NEXT for at most k descriptors.
def walk(k: Nat, +more: Bool, s: DS, +q: Q, +r: U32, +w: U32, +sa: U32, +ha: U32) -> SM:
  match k more:
    case 1n+p True{}:
      DS{m, d, +a, +l, +f} = s
      +wr = nz(U32.and(f, 2))
      walk(p, nz(U32.and(f, 1)), ds.rd(m, d, q, U32.shrn(f, 16n)), q, sel(wr, r, U32.add(r, l)), sel(wr, U32.add(w, l), w), sel(Bool.and(wr, nz(l)), U32.add(a, U32.sub(l, 1)), sa), sel(Bool.or(wr, nz(r)), ha, a))
    case _ _:
      DS{m, d, a, l, f} = s
      SM{m, d, r, w, sa, ha}

def chain.sum(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32) -> SM:
  walk(qn(q), True{}, ds.rd(m, d, q, h), q, 0, 0, 0, 0)

# Copies n bytes from d byte address s into the chain's writable buffers.
def wchain(k: Nat, +more: Bool, c: DS, +q: Q, +n: U32, +s: U32) -> MD:
  match k more:
    case 1n+p True{}:
      DS{m, d, +a, +l, +f} = c
      +x = sel(nz(U32.and(f, 2)), umin(l, n), 0)
      wchain(p, Bool.and(nz(U32.and(f, 1)), U32.is_ne(x, n)), ds.next(cp.dm(m, d, a, s, x), q, U32.shrn(f, 16n)), q, U32.sub(n, x), U32.add(s, x))
    case _ _:
      DS{m, d, a, l, f} = c
      MD{m, d}

# Copies n bytes of the chain's readable buffers, after the first `skip`
# bytes, to d byte address s.
def rchain(k: Nat, +more: Bool, c: DS, +q: Q, +skip: U32, +n: U32, +s: U32) -> MD:
  match k more:
    case 1n+p True{}:
      DS{m, d, +a, +l, +f} = c
      +rd = U32.is_zero(U32.and(f, 2))
      +sk = sel(rd, umin(skip, l), 0)
      +x = sel(rd, umin(U32.sub(l, sk), n), 0)
      rchain(p, Bool.and(nz(U32.and(f, 1)), U32.is_ne(x, n)), ds.next(cp.md(m, d, U32.add(a, sk), s, x), q, U32.shrn(f, 16n)), q, U32.sub(skip, sk), U32.sub(n, x), U32.add(s, x))
    case _ _:
      DS{m, d, a, l, f} = c
      MD{m, d}

def chain.put(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +n: U32, +s: U32) -> MD:
  wchain(qn(q), nz(n), ds.rd(m, d, q, h), q, n, s)

def chain.get(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +skip: U32, +n: U32, +s: U32) -> MD:
  rchain(qn(q), nz(n), ds.rd(m, d, q, h), q, skip, n, s)

def hd.k(d: Array<U32>, p: Array<U32> & U32) -> VA:
  (m, h) = p
  VA{m, d, h}

# the chain head at avail position i
def hd.rd(m: Array<U32>, d: Array<U32>, +q: Q, +i: U32) -> VA:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  hd.k(d, gh(m, U32.add(U32.add(avail, 4), U32.shln(U32.and(i, U32.sub(num, 1)), 1n))))

def hd.next(r: MD, +q: Q, +i: U32) -> VA:
  MD{m, d} = r
  hd.rd(m, d, q, i)

def up.k(+e: U32, +h: U32, r: VA) -> MD:
  VA{m, d, v} = r
  MD{sw(sw(m, e, h), U32.add(e, 4), v), d}

# used ring element u = {id h, len r.v}
def used.put(r: VA, +q: Q, +u: U32, +h: U32) -> MD:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  up.k(U32.add(U32.add(used, 4), U32.shln(U32.and(u, U32.sub(num, 1)), 3n)), h, r)

def isr.k(+on: Bool, +b: U32, p: Array<U32> & U32) -> Array<U32>:
  (d, +s) = p
  Array.set(U32, d, U32.add(b, 6), U32.or(s, bit(on)))

# InterruptStatus |= 1 (used buffer) when on
def isr.raise(+on: Bool, d: Array<U32>, +b: U32) -> Array<U32>:
  isr.k(on, b, Array.get(U32, d, U32.add(b, 6)))

# p = (m, avail.flags): interrupt unless the driver set NO_INTERRUPT
def irq.c(+b: U32, +v: U32, p: Array<U32> & U32, d: Array<U32>) -> VA:
  (m, +fl) = p
  VA{m, isr.raise(U32.is_zero(U32.and(fl, 1)), d, b), v}

# After completions: publishes used.idx = u and interrupts.
def irq(m: Array<U32>, d: Array<U32>, +b: U32, +q: Q, +u: U32, +v: U32) -> VA:
  Q{rdy, num, desc, avail, used, last, uidx} = q
  irq.c(b, v, gh(shw(m, U32.add(used, 2), u), avail), d)

# Block device
# ------------

def blk.st(r: MD, +sa: U32, +st: U32, +len: U32) -> VA:
  MD{m, d} = r
  VA{sb(m, sa, st), d, len}

# n bytes at sector (shi, slo) lie on a disk of cap sectors (cap < 2^23)
def blk.fits(+slo: U32, +shi: U32, +n: U32, +cap: U32) -> Bool:
  +off = U32.shln(slo, 9n)
  +end = U32.add(off, n)
  Bool.and(Bool.and(U32.is_zero(shi), U32.is_lt(slo, 8388608)), Bool.and(U32.is_ge(end, off), U32.is_le(end, U32.shln(cap, 9n))))

def blk.in.k(+ok: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +sa: U32, +slo: U32, +n: U32) -> VA:
  match ok:
    case True{}:
      blk.st(chain.put(m, d, q, h, n, U32.add(DISK(), U32.shln(slo, 9n))), sa, 0, U32.add(n, 1))
    case False{}:
      VA{sb(m, sa, 1), d, 1}

# VIRTIO_BLK_T_IN: disk -> the writable buffers but the last byte
def blk.in(m: Array<U32>, p: Array<U32> & U32, +q: Q, +h: U32, +sa: U32, +slo: U32, +shi: U32, +n: U32) -> VA:
  (d, +cap) = p
  blk.in.k(blk.fits(slo, shi, n, cap), m, d, q, h, sa, slo, n)

def blk.out.k(+ok: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +sa: U32, +slo: U32, +n: U32) -> VA:
  match ok:
    case True{}:
      blk.st(chain.get(m, d, q, h, 16, n, U32.add(DISK(), U32.shln(slo, 9n))), sa, 0, 1)
    case False{}:
      VA{sb(m, sa, 1), d, 1}

# VIRTIO_BLK_T_OUT: the readable buffers after the header -> disk
def blk.out(m: Array<U32>, p: Array<U32> & U32, +q: Q, +h: U32, +sa: U32, +slo: U32, +shi: U32, +n: U32) -> VA:
  (d, +cap) = p
  blk.out.k(blk.fits(slo, shi, n, cap), m, d, q, h, sa, slo, n)

# VIRTIO_BLK_T_GET_ID: "wiltee", zero-padded to the buffer, at most 20 bytes
def blk.id(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +sa: U32, +wl: U32) -> VA:
  +n = umin(U32.sub(wl, 1), 20)
  d[IDW()] <- 1953261943
  d[U32.add(IDW(), 1)] <- 25957
  d[U32.add(IDW(), 2)] <- 0
  d[U32.add(IDW(), 3)] <- 0
  d[U32.add(IDW(), 4)] <- 0
  blk.st(chain.put(m, d, q, h, n, U32.shln(IDW(), 2n)), sa, 0, U32.add(n, 1))

# 101: no status byte, 100: no header, else the request type
def blk.code(+rl: U32, +wl: U32, +ty: U32) -> U32:
  sel(U32.is_zero(wl), 101, sel(U32.is_lt(rl, 16), 100, ty))

def blk.c(+code: U32, m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +rl: U32, +wl: U32, +sa: U32, +slo: U32, +shi: U32) -> VA:
  match code:
    case 0:
      blk.in(m, Array.get(U32, d, CAP()), q, h, sa, slo, shi, U32.sub(wl, 1))
    case 1:
      blk.out(m, Array.get(U32, d, CAP()), q, h, sa, slo, shi, U32.sub(rl, 16))
    case 4:
      VA{sb(m, sa, 0), d, 1}
    case 8:
      blk.id(m, d, q, h, sa, wl)
    case 100:
      VA{sb(m, sa, 1), d, 1}
    case 101:
      VA{m, d, 0}
    case _:
      VA{sb(m, sa, 2), d, 1}

def blk.b(d: Array<U32>, r: R3, +q: Q, +h: U32, +rl: U32, +wl: U32, +sa: U32) -> VA:
  R3{m, +ty, +slo, +shi} = r
  blk.c(blk.code(rl, wl, ty), m, d, q, h, rl, wl, sa, slo, shi)

def blk.a(r: SM, +q: Q, +h: U32) -> VA:
  SM{m, d, +rl, +wl, +sa, +ha} = r
  blk.b(d, g3(m, ha, U32.add(ha, 8), U32.add(ha, 12)), q, h, rl, wl, sa)

# One request (chain head h); v = bytes written to the guest.
def blk.req(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32) -> VA:
  blk.a(chain.sum(m, d, q, h), q, h)

# Network device: transmit
# ------------------------

def tx.fin(r: MD) -> VA:
  MD{m, d} = r
  VA{m, d, 0}

def tx.c(+ok: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +h: U32, +fill: U32, +n: U32) -> VA:
  match ok:
    case True{}:
      +at = U32.add(TXB(), fill)
      d = dbs(d, at, U32.and(n, 255))
      d = dbs(d, U32.add(at, 1), U32.shrn(n, 8n))
      d[TXF()] <- U32.add(fill, U32.add(n, 2))
      tx.fin(chain.get(m, d, q, h, 12, n, U32.add(at, 2)))
    case False{}:
      VA{m, d, 0}

def tx.b(m: Array<U32>, p: Array<U32> & U32, +q: Q, +h: U32, +rl: U32) -> VA:
  (d, +fill) = p
  +n = U32.sub(rl, 12)
  tx.c(Bool.and(U32.is_ge(rl, 12), Bool.and(U32.is_le(n, 65535), U32.is_le(U32.add(fill, U32.add(n, 2)), BUF()))), m, d, q, h, fill, n)

def tx.a(r: SM, +q: Q, +h: U32) -> VA:
  SM{m, d, +rl, wl, sa, ha} = r
  tx.b(m, Array.get(U32, d, TXF()), q, h, rl)

# One frame: drops the 12-byte header and queues the rest for the host
# (dropped when the buffer is full); v = 0, nothing is written back.
def tx.req(m: Array<U32>, d: Array<U32>, +q: Q, +h: U32) -> VA:
  tx.a(chain.sum(m, d, q, h), q, h)

# Request queues (block 0, network 1)
# -----------------------------------

def req(+kind: U32, m: Array<U32>, d: Array<U32>, +q: Q, +h: U32) -> VA:
  match kind:
    case 0:
      blk.req(m, d, q, h)
    case _:
      tx.req(m, d, q, h)

# Runs k requests from avail position i, completing them at used position u;
# c carries the arrays and the head of the request at i.
def qloop(k: Nat, c: VA, +kind: U32, +q: Q, +i: U32, +u: U32) -> MD:
  match k:
    case 0n:
      VA{m, d, h} = c
      MD{m, d}
    case 1n+p:
      VA{m, d, +h} = c
      qloop(p, hd.next(used.put(req(kind, m, d, q, h), q, u, h), q, U32.add(i, 1)), kind, q, U32.add(i, 1), U32.add(u, 1))

def qrun.fin(r: MD, +b: U32, +qb: U32, +q: Q, +cnt: U32) -> VA:
  MD{m, d} = r
  Q{rdy, num, desc, avail, used, +last, +uidx} = q
  +u = U32.and(U32.add(uidx, cnt), 65535)
  d[U32.add(qb, 8)] <- U32.and(U32.add(last, cnt), 65535)
  d[U32.add(qb, 9)] <- u
  irq(m, d, b, q, u, cnt)

def qrun.d(+any: Bool, +kind: U32, +b: U32, +qb: U32, +q: Q, +cnt: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match any:
    case True{}:
      Q{rdy, num, desc, avail, used, +last, +uidx} = q
      qrun.fin(qloop(U32.to_nat(cnt), hd.rd(m, d, q, last), kind, q, last, uidx), b, qb, q, cnt)
    case False{}:
      VA{m, d, 0}

# p = (m, avail.idx)
def qrun.c(+kind: U32, +b: U32, +qb: U32, +q: Q, p: Array<U32> & U32, d: Array<U32>) -> VA:
  Q{rdy, +num, desc, avail, used, +last, uidx} = q
  (m, +ai) = p
  +cnt = umin(U32.and(U32.sub(ai, last), 65535), num)
  qrun.d(nz(cnt), kind, b, qb, q, cnt, m, d)

def qrun.b(+ok: Bool, +kind: U32, +b: U32, +qb: U32, +q: Q, m: Array<U32>, d: Array<U32>) -> VA:
  match ok:
    case True{}:
      Q{rdy, num, desc, +avail, used, last, uidx} = q
      qrun.c(kind, b, qb, q, gh(m, U32.add(avail, 2)), d)
    case False{}:
      VA{m, d, 0}

def qrun.a(+kind: U32, +b: U32, +qb: U32, m: Array<U32>, r: DQ) -> VA:
  DQ{d, +q} = r
  qrun.b(q.ok(q), kind, b, qb, q, m, d)

# Completes every request the driver has made available on queue qn of dev.
def qrun(+kind: U32, +dev: U32, +qn: U32, m: Array<U32>, d: Array<U32>) -> VA:
  qrun.a(kind, base(dev), qbase(dev, qn), m, ql(d, qbase(dev, qn)))

# Network device: receive
# -----------------------

def rx.e(r: MD, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32) -> RS:
  MD{m, d} = r
  RS{m, d, Bool.and(U32.is_ne(hd, tl), U32.is_ne(i, aidx)), i, u, hd, n}

def rx.len(r: MD, +len: U32) -> VA:
  MD{m, d} = r
  VA{m, d, len}

def rx.d(+fits: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32, +l: U32, +h: U32, +nhd: U32) -> RS:
  match fits:
    case True{}:
      +len = U32.add(l, 12)
      rx.e(used.put(rx.len(chain.put(m, d, q, h, len, U32.add(U32.add(RXB(), hd), 2)), len), q, u, h), aidx, tl, U32.and(U32.add(i, 1), 65535), U32.and(U32.add(u, 1), 65535), nhd, U32.add(n, 1))
    case False{}:
      # too big for the buffer: dropped, and the buffer stays posted
      RS{m, d, Bool.and(U32.is_ne(nhd, tl), U32.is_ne(i, aidx)), i, u, nhd, n}

def rx.c(r: SM, +q: Q, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32, +l: U32, +h: U32) -> RS:
  SM{m, d, rl, +wl, sa, ha} = r
  rx.d(U32.is_le(U32.add(l, 12), wl), m, d, q, aidx, tl, i, u, hd, n, l, h, U32.add(hd, up4(U32.add(l, 14))))

def rx.b(c: VA, +q: Q, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32, +l: U32) -> RS:
  VA{m, d, +h} = c
  rx.c(chain.sum(m, d, q, h), q, aidx, tl, i, u, hd, n, l, h)

def rx.a(m: Array<U32>, p: Array<U32> & U32, +q: Q, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32) -> RS:
  (d, +w) = p
  rx.b(hd.rd(m, d, q, i), q, aidx, tl, i, u, hd, n, U32.and(w, 65535))

# Moves the frame at buffer offset hd into the buffer chain at avail position i.
def rx.one(m: Array<U32>, d: Array<U32>, +q: Q, +aidx: U32, +tl: U32, +i: U32, +u: U32, +hd: U32, +n: U32) -> RS:
  rx.a(m, Array.get(U32, d, U32.shrn(U32.add(RXB(), hd), 2n)), q, aidx, tl, i, u, hd, n)

def rxloop(k: Nat, s: RS, +q: Q, +aidx: U32, +tl: U32) -> RS:
  match k s:
    case 1n+p RS{m, d, True{}, +i, +u, +hd, +n}:
      rxloop(p, rx.one(m, d, q, aidx, tl, i, u, hd, n), q, aidx, tl)
    case _ _:
      s

def rx.fin.k(+any: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +u: U32, +n: U32) -> VA:
  match any:
    case True{}:
      irq(m, d, NET(), q, u, n)
    case False{}:
      VA{m, d, 0}

def rx.fin(r: RS, +q: Q, +tl: U32) -> VA:
  RS{m, d, go, +i, +u, +hd, +n} = r
  +empty = U32.is_eq(hd, tl)
  d[RXH()] <- sel(empty, 0, hd)
  d[RXT()] <- sel(empty, 0, tl)
  d[U32.add(RXQ(), 8)] <- i
  d[U32.add(RXQ(), 9)] <- u
  rx.fin.k(nz(n), m, d, q, u, n)

# p = (m, avail.idx)
def rx.run.e(p: Array<U32> & U32, d: Array<U32>, +q: Q, +hd: U32, +tl: U32) -> VA:
  (m, +ai) = p
  Q{rdy, num, desc, avail, used, +last, +uidx} = q
  rx.fin(rxloop(8192n, RS{m, d, U32.is_ne(ai, last), last, uidx, hd, 0}, q, ai, tl), q, tl)

def rx.run.d(+ok: Bool, m: Array<U32>, d: Array<U32>, +q: Q, +hd: U32, +tl: U32) -> VA:
  match ok:
    case True{}:
      Q{rdy, num, desc, +avail, used, last, uidx} = q
      rx.run.e(gh(m, U32.add(avail, 2)), d, q, hd, tl)
    case False{}:
      VA{m, d, 0}

def rx.run.c(m: Array<U32>, r: DQ, +hd: U32, +tl: U32) -> VA:
  DQ{d, +q} = r
  rx.run.d(q.ok(q), m, d, q, hd, tl)

def rx.run.b(+any: Bool, m: Array<U32>, d: Array<U32>, +hd: U32, +tl: U32) -> VA:
  match any:
    case True{}:
      rx.run.c(m, ql(d, RXQ()), hd, tl)
    case False{}:
      VA{m, d, 0}

def rx.run.a(m: Array<U32>, r: R2) -> VA:
  R2{d, +hd, +tl} = r
  rx.run.b(U32.is_ne(hd, tl), m, d, hd, tl)

# Delivers waiting host frames into posted receive buffers, in order, while
# both last; v = frames delivered. Costs two reads when no frame waits.
def rx.run(m: Array<U32>, d: Array<U32>) -> VA:
  rx.run.a(m, get2(d, RXH(), RXT()))

# Registers
# ---------

# DeviceFeatures: VIRTIO_F_VERSION_1 (bit 32); the network adds
# VIRTIO_NET_F_MAC (bit 5).
def feat(+dev: U32, +s: U32) -> U32:
  sel(U32.is_eq(s, 1), 1, sel(U32.is_zero(s), U32.shln(U32.and(dev, 1), 5n), 0))

# Bytes c..c+3 of the 64-bit little-endian (hi, lo), zero past byte 7.
def cfg4(+c: U32, +lo: U32, +hi: U32) -> U32:
  match c:
    case 0:
      lo
    case 1:
      U32.or(U32.shrn(lo, 8n), U32.shln(hi, 24n))
    case 2:
      U32.or(U32.shrn(lo, 16n), U32.shln(hi, 16n))
    case 3:
      U32.or(U32.shrn(lo, 24n), U32.shln(hi, 8n))
    case 4:
      hi
    case 5:
      U32.shrn(hi, 8n)
    case 6:
      U32.shrn(hi, 16n)
    case 7:
      U32.shrn(hi, 24n)
    case _:
      0

def rd.cfg.blk(+c: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +cap) = p
  VA{m, d, cfg4(c, cap, 0)}

# 52:54:00:12:34:xx, xx = 0x56 until net.mac
def rd.cfg.net(+c: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +mac) = p
  VA{m, d, cfg4(c, 302011474, U32.or(52, U32.shln(sel(nz(U32.and(mac, 256)), U32.and(mac, 255), 86), 8n)))}

# Config space, from byte c: block capacity (u64, sectors); network mac[6].
def rd.cfg(+dev: U32, +c: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match dev:
    case 0:
      rd.cfg.blk(c, m, Array.get(U32, d, CAP()))
    case _:
      rd.cfg.net(c, m, Array.get(U32, d, MAC()))

# DeviceID: 2 block (0, no device, until a disk is attached), 1 network
def rd.id(+dev: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +cap) = p
  VA{m, d, sel(U32.is_zero(dev), sel(nz(cap), 2, 0), 1)}

def rd.feat(+dev: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  VA{m, d, feat(dev, s)}

def rd.qmax(+dev: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  VA{m, d, sel(U32.is_lt(s, nq(dev)), QMAX(), 0)}

def rd.qrdy.k(+ok: Bool, +qb: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match ok:
    case True{}:
      va.k(m, Array.get(U32, d, U32.add(qb, 1)))
    case False{}:
      VA{m, d, 0}

def rd.qrdy(+dev: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  rd.qrdy.k(U32.is_lt(s, nq(dev)), qbase(dev, s), m, d)

def rd.reg(+o: U32, +dev: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match o:
    case 0:
      VA{m, d, 1953655158}
    case 4:
      VA{m, d, 2}
    case 8:
      rd.id(dev, m, Array.get(U32, d, CAP()))
    case 12:
      VA{m, d, 1431127377}
    case 16:
      rd.feat(dev, m, Array.get(U32, d, U32.add(base(dev), 1)))
    case 52:
      rd.qmax(dev, m, Array.get(U32, d, U32.add(base(dev), 5)))
    case 68:
      rd.qrdy(dev, m, Array.get(U32, d, U32.add(base(dev), 5)))
    case 96:
      va.k(m, Array.get(U32, d, U32.add(base(dev), 6)))
    case 112:
      va.k(m, Array.get(U32, d, base(dev)))
    case 176:
      VA{m, d, 4294967295}
    case 180:
      VA{m, d, 4294967295}
    case 184:
      VA{m, d, 4294967295}
    case 188:
      VA{m, d, 4294967295}
    case _:
      VA{m, d, 0}

def rd.a(+cfg: Bool, +dev: U32, +o: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match cfg:
    case True{}:
      rd.cfg(dev, U32.sub(o, 256), m, d)
    case False{}:
      rd.reg(o, dev, m, d)

def wr.feat.k(+s: U32, +b: U32, +val: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match s:
    case 0:
      VA{m, Array.set(U32, d, U32.add(b, 3), val), 0}
    case 1:
      VA{m, Array.set(U32, d, U32.add(b, 4), val), 0}
    case _:
      VA{m, d, 0}

def wr.feat(+b: U32, +val: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  wr.feat.k(s, b, val, m, d)

def wr.ack(+b: U32, +val: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  VA{m, Array.set(U32, d, U32.add(b, 6), U32.and(s, U32.not(val))), 0}

def wr.q.k(+ok: Bool, +qb: U32, +f: U32, +val: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match ok:
    case True{}:
      VA{m, Array.set(U32, d, U32.add(qb, f), val), 0}
    case False{}:
      VA{m, d, 0}

def wr.q.a(+dev: U32, +f: U32, +val: U32, m: Array<U32>, p: Array<U32> & U32) -> VA:
  (d, +s) = p
  wr.q.k(U32.is_lt(s, nq(dev)), qbase(dev, s), f, val, m, d)

# field f of the selected queue (ignored when QueueSel names no queue)
def wr.q(+dev: U32, +f: U32, +val: U32, m: Array<U32>, d: Array<U32>) -> VA:
  wr.q.a(dev, f, val, m, Array.get(U32, d, U32.add(base(dev), 5)))

def zero(k: Nat, d: Array<U32>, +i: U32) -> Array<U32>:
  match k:
    case 0n:
      d
    case 1n+p:
      zero(p, Array.set(U32, d, i, 0), U32.add(i, 1))

# Status; 0 resets the device (the disk, the MAC and the frame buffers stay).
def wr.status(+val: U32, +b: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match val:
    case 0:
      VA{m, zero(32n, zero(8n, d, b), U32.add(b, 16)), 0}
    case _:
      VA{m, Array.set(U32, d, b, val), 0}

def notify(+code: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match code:
    case 1:
      qrun(0, 0, 0, m, d)
    case 2:
      rx.run(m, d)
    case 3:
      qrun(1, 1, 1, m, d)
    case _:
      VA{m, d, 0}

# 1: block queue 0, 2: receive queue, 3: transmit queue, 0: none
def ncode(+dev: U32, +q: U32) -> U32:
  sel(U32.is_zero(dev), bit(U32.is_zero(q)), sel(U32.is_zero(q), 2, sel(U32.is_eq(q, 1), 3, 0)))

def wr.reg(+o: U32, +dev: U32, +val: U32, m: Array<U32>, d: Array<U32>) -> VA:
  match o:
    case 20:
      VA{m, Array.set(U32, d, U32.add(base(dev), 1), val), 0}
    case 32:
      wr.feat(base(dev), val, m, Array.get(U32, d, U32.add(base(dev), 2)))
    case 36:
      VA{m, Array.set(U32, d, U32.add(base(dev), 2), val), 0}
    case 48:
      VA{m, Array.set(U32, d, U32.add(base(dev), 5), val), 0}
    case 56:
      wr.q(dev, 0, umin(val, QMAX()), m, d)
    case 68:
      wr.q(dev, 1, U32.and(val, 1), m, d)
    case 80:
      notify(ncode(dev, val), m, d)
    case 100:
      wr.ack(base(dev), val, m, Array.get(U32, d, U32.add(base(dev), 6)))
    case 112:
      wr.status(val, base(dev), m, d)
    case 128:
      wr.q(dev, 2, val, m, d)
    case 132:
      wr.q(dev, 3, val, m, d)
    case 144:
      wr.q(dev, 4, val, m, d)
    case 148:
      wr.q(dev, 5, val, m, d)
    case 160:
      wr.q(dev, 6, val, m, d)
    case 164:
      wr.q(dev, 7, val, m, d)
    case _:
      VA{m, d, 0}

# Host frames
# -----------

def take.go(k: Nat, dv: Array<U32> & U32, +b: U32, acc: List<&2, U32>) -> Array<U32> & List<&2, U32>:
  match k:
    case 0n:
      (d, v) = dv
      (d, acc)
    case 1n+p:
      (d, v) = dv
      take.go(p, db(d, U32.sub(b, 1)), U32.sub(b, 1), v <> acc)

def take.fin(r: Array<U32> & List<&2, U32>) -> Array<U32> & List<&2, U32>:
  (d, bs) = r
  d[TXF()] <- 0
  (d, bs)

def take.a(p: Array<U32> & U32) -> Array<U32> & List<&2, U32>:
  (d, +fill) = p
  +e = U32.add(TXB(), U32.sub(fill, 1))
  take.fin(take.go(U32.to_nat(fill), db(d, e), e, Nil{}))

# k bytes from the list to d byte addresses from b
def put.b(k: Nat, fs: List<&2, U32>, d: Array<U32>, +b: U32) -> DL:
  match k fs:
    case 1n+p Con{x, rest}:
      put.b(p, rest, dbs(d, b, x), U32.add(b, 1))
    case _ _:
      DL{d, fs}

# k words (4 list bytes each) to d[i..]
def put.w(k: Nat, fs: List<&2, U32>, d: Array<U32>, +i: U32) -> DL:
  match k fs:
    case 1n+p Con{x0, Con{x1, Con{x2, Con{x3, rest}}}}:
      put.w(p, rest, Array.set(U32, d, i, U32.or(U32.or(U32.and(x0, 255), U32.shln(U32.and(x1, 255), 8n)), U32.or(U32.shln(U32.and(x2, 255), 16n), U32.shln(x3, 24n)))), U32.add(i, 1))
    case _ _:
      DL{d, fs}

def give.f(r: DL, +tl: U32) -> GS:
  DL{d, fs} = r
  GS{d, fs, tl}

def give.e(r: DL, +b: U32, +t: U32, +tl: U32) -> GS:
  DL{d, fs} = r
  give.f(put.b(U32.to_nat(t), fs, d, b), tl)

def give.c(r: DL, +w4: U32, +l: U32, +tl: U32) -> GS:
  DL{d, fs} = r
  +rest = U32.sub(l, umin(l, 2))
  give.e(put.w(U32.to_nat(U32.shrn(rest, 2n)), fs, d, w4), U32.add(U32.shln(w4, 2n), wal(rest)), U32.and(rest, 3), tl)

def give.put(+fits: Bool, d: Array<U32>, fs: List<&2, U32>, +tl: U32, +l: U32, +need: U32) -> GS:
  match fits:
    case True{}:
      # [len, header with num_buffers = 1] then the frame from byte 14
      +w = U32.shrn(U32.add(RXB(), tl), 2n)
      d[w] <- l
      d[U32.add(w, 1)] <- 0
      d[U32.add(w, 2)] <- 0
      d[U32.add(w, 3)] <- 1
      give.c(put.b(U32.to_nat(umin(l, 2)), fs, d, U32.add(U32.add(RXB(), tl), 14)), U32.add(w, 4), l, U32.add(tl, need))
    case False{}:
      GS{d, List.drop(&2, U32, fs, U32.to_nat(l)), tl}

def give.one(d: Array<U32>, fs: List<&2, U32>, +tl: U32, +lo: U32, +hi: U32) -> GS:
  +l = U32.or(U32.and(lo, 255), U32.shln(U32.and(hi, 255), 8n))
  +need = up4(U32.add(l, 14))
  give.put(U32.is_le(U32.add(tl, need), BUF()), d, fs, tl, l, need)

# one frame per step (each takes at least two list cells)
def give.go(k: Nat, s: GS) -> GS:
  match k s:
    case 1n+p GS{d, Con{lo, Con{hi, rest}}, +tl}:
      give.go(p, give.one(d, rest, tl, lo, hi))
    case _ _:
      s

def give.fin(s: GS) -> Array<U32>:
  GS{d, fs, tl} = s
  d[RXT()] <- tl
  d

# k words from d[src..] down to d[dst..] (dst < src); q = (d, d[src])
def mv(k: Nat, q: Array<U32> & U32, +dst: U32, +src: U32) -> Array<U32>:
  match k:
    case 0n:
      (d, w) = q
      d
    case 1n+p:
      (d, +w) = q
      mv(p, Array.get(U32, Array.set(U32, d, dst, w), U32.add(src, 1)), U32.add(dst, 1), U32.add(src, 1))

# Records still waiting move to the front first, so the whole buffer is usable.
def give.b(+c: Bool, +fs: List<&2, U32>, d: Array<U32>, +hd: U32, +tl: U32) -> Array<U32>:
  match c:
    case True{}:
      +n = U32.sub(tl, hd)
      +s = U32.shrn(U32.add(RXB(), hd), 2n)
      d = mv(U32.to_nat(U32.shrn(n, 2n)), Array.get(U32, d, s), U32.shrn(RXB(), 2n), s)
      d[RXH()] <- 0
      give.fin(give.go(List.length(&2, U32, fs), GS{d, fs, n}))
    case False{}:
      give.fin(give.go(List.length(&2, U32, fs), GS{d, fs, tl}))

def give.a(+fs: List<&2, U32>, r: R2) -> Array<U32>:
  R2{d, +hd, +tl} = r
  give.b(nz(hd), fs, d, hd, tl)

# Interface
# ---------

# A 32-bit read at physical pa in 0xF5000000..0xF5001FFF. In config space
# (offset 0x100 and up) v holds the bytes from pa on, so 8- and 16-bit reads
# take its low bits.
def rd(+pa: U32, m: Array<U32>, d: Array<U32>) -> VA:
  rd.a(U32.is_ge(U32.and(pa, 4095), 256), U32.and(U32.shrn(pa, 12n), 1), U32.and(pa, 4095), m, d)

# A 32-bit write; a QueueNotify runs the queue's requests before returning.
def wr(+pa: U32, +val: U32, m: Array<U32>, d: Array<U32>) -> VA:
  wr.reg(U32.and(pa, 4095), U32.and(U32.shrn(pa, 12n), 1), val, m, d)

# The asserted interrupt lines as PLIC bits: 4 block, 8 network.
def lines.k(+a: U32, p: Array<U32> & U32) -> Array<U32> & U32:
  (d, +b) = p
  (d, U32.or(U32.shln(bit(nz(a)), 2n), U32.shln(bit(nz(b)), 3n)))

def lines.a(p: Array<U32> & U32) -> Array<U32> & U32:
  (d, +a) = p
  lines.k(a, Array.get(U32, d, U32.add(NET(), 6)))

def lines(d: Array<U32>) -> Array<U32> & U32:
  lines.a(Array.get(U32, d, U32.add(BLK(), 6)))

# Delivers waiting host frames into posted receive buffers.
def poll(m: Array<U32>, d: Array<U32>) -> VA:
  rx.run(m, d)

# The host has loaded a disk of `bytes` bytes at d[1048576..].
def blk.attach(+bytes: U32, d: Array<U32>) -> Array<U32>:
  Array.set(U32, d, CAP(), U32.shrn(bytes, 9n))

# Drains the frames the guest sent: [len_lo, len_hi, byte0, ...] per frame.
def net.take(d: Array<U32>) -> Array<U32> & List<&2, U32>:
  take.a(Array.get(U32, d, TXF()))

# Queues frames for the guest, same encoding; what does not fit is dropped.
def net.give(fs: List<&2, U32>, d: Array<U32>) -> Array<U32>:
  give.a(fs, get2(d, RXH(), RXT()))

# The MAC becomes 52:54:00:12:34:(id & 255).
def net.mac(+id: U32, d: Array<U32>) -> Array<U32>:
  Array.set(U32, d, MAC(), U32.or(256, U32.and(id, 255)))
