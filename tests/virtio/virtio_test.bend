import Base
import ../../src/virtio.bend as V

# Drives src/virtio.bend the way Linux's virtio_mmio, virtio_blk and
# virtio_net drivers do: the status handshake, split virtqueues laid out in
# guest RAM, requests posted on the avail ring and kicked with QueueNotify,
# completions read back from the used ring. Prints one PASS/FAIL line per
# check and exits with status 1 if any check failed.

# m: guest RAM (4 MiB), d: device words (2^21: 4 MiB of disk), the log
# (newest first), checks run, checks failed
type T is Type:
  T{m: Array<U32>, d: Array<U32>, log: List<String>, n: U32, bad: U32}

# MMIO bases
def B() -> U32:
  4110417920

def N() -> U32:
  4110422016

def at(+base: U32, +o: U32) -> U32:
  U32.add(base, o)

# Patterns
# --------

# initial disk byte o
def dpat(+o: U32) -> U32:
  U32.and(U32.add(U32.mul(o, 7), U32.shrn(o, 9n)), 255)

def dword(+j: U32) -> U32:
  +o = U32.shln(j, 2n)
  U32.or(U32.or(dpat(o), U32.shln(dpat(U32.add(o, 1)), 8n)), U32.or(U32.shln(dpat(U32.add(o, 2)), 16n), U32.shln(dpat(U32.add(o, 3)), 24n)))

# byte i of a guest data pattern
def spat(+i: U32, +seed: U32) -> U32:
  U32.and(U32.add(U32.mul(i, 13), seed), 255)

# [spat(j-k, seed) .. spat(j-1, seed)] ++ acc
def gen(k: Nat, +j: U32, +seed: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      gen(p, U32.sub(j, 1), seed, spat(U32.sub(j, 1), seed) <> acc)

# [dpat(o-k) .. dpat(o-1)] ++ acc
def dgen(k: Nat, +o: U32, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      dgen(p, U32.sub(o, 1), dpat(U32.sub(o, 1)) <> acc)

def zeros(k: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      zeros(p, 0 <> acc)

# a received virtio_net_hdr_v1: zero but num_buffers = 1
def hdr(rest: List<&2, U32>) -> List<&2, U32>:
  zeros(10n, 1 <> (0 <> rest))

# a frame of n pattern bytes in the host encoding [len_lo, len_hi, bytes]
def enc(+n: U32, +seed: U32, rest: List<&2, U32>) -> List<&2, U32>:
  U32.and(n, 255) <> (U32.shrn(n, 8n) <> gen(U32.to_nat(n), n, seed, rest))

def many(k: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      acc
    case 1n+p:
      many(p, enc(1500, 21, acc))

def leq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case Con{x, xr} Con{y, yr}:
      Bool.and(U32.is_eq(x, y), leq(xr, yr))
    case _ _:
      False{}

def fill(k: Nat, d: Array<U32>, +j: U32) -> Array<U32>:
  match k:
    case 0n:
      d
    case 1n+p:
      fill(p, Array.set(U32, d, U32.add(1048576, j), dword(j)), U32.add(j, 1))

# Machine access
# --------------

def t.va(r: V.VA, log: List<String>, +n: U32, +bad: U32) -> T:
  V.VA{m, d, v} = r
  T{m, d, log, n, bad}

def t.vv(r: V.VA, log: List<String>, +n: U32, +bad: U32) -> T & U32:
  V.VA{m, d, +v} = r
  (T{m, d, log, n, bad}, v)

def wr(+pa: U32, +v: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  t.va(V.wr(pa, v, m, d), log, n, bad)

def rd(+pa: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.vv(V.rd(pa, m, d), log, n, bad)

def poll(t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.vv(V.poll(m, d), log, n, bad)

def t.mp(p: Array<U32> & U32, d: Array<U32>, log: List<String>, +n: U32, +bad: U32) -> T & U32:
  (m, +v) = p
  (T{m, d, log, n, bad}, v)

def t.dp(m: Array<U32>, p: Array<U32> & U32, log: List<String>, +n: U32, +bad: U32) -> T & U32:
  (d, +v) = p
  (T{m, d, log, n, bad}, v)

# guest RAM: words, 16-bit words, bytes
def mrd(+pa: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.mp(V.gw(m, pa), d, log, n, bad)

def mwr(+pa: U32, +w: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{V.sw(m, pa, w), d, log, n, bad}

def mrh(+pa: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.mp(V.gh(m, pa), d, log, n, bad)

def mwh(+pa: U32, +h: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{V.shw(m, pa, h), d, log, n, bad}

def mrb(+pa: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.mp(V.gb(m, pa), d, log, n, bad)

def mwb(+pa: U32, +b: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{V.sb(m, pa, b), d, log, n, bad}

# device words and d bytes
def drd(+i: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.dp(m, Array.get(U32, d, i), log, n, bad)

def drb(+b: U32, t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.dp(m, V.db(d, b), log, n, bad)

def lines(t: T) -> T & U32:
  T{m, d, log, +n, +bad} = t
  t.dp(m, V.lines(d), log, n, bad)

def t.tk(m: Array<U32>, p: Array<U32> & List<&2, U32>, log: List<String>, +n: U32, +bad: U32) -> T & List<&2, U32>:
  (d, xs) = p
  (T{m, d, log, n, bad}, xs)

def take(t: T) -> T & List<&2, U32>:
  T{m, d, log, +n, +bad} = t
  t.tk(m, V.net.take(d), log, n, bad)

def give(fs: List<&2, U32>, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{m, V.net.give(fs, d), log, n, bad}

def setmac(+id: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{m, V.net.mac(id, d), log, n, bad}

# a 64 KiB disk (128 sectors) of dpat bytes
def attach(t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{m, V.blk.attach(65536, fill(16384n, d, 0)), log, n, bad}

def mputl(xs: List<&2, U32>, t: T, +ga: U32) -> T:
  match xs:
    case Nil{}:
      t
    case Con{x, rest}:
      mputl(rest, mwb(ga, x, t), U32.add(ga, 1))

# mismatches between guest bytes from ga and xs; p = (t, the byte at ga)
def mcmpl(xs: List<&2, U32>, p: T & U32, +ga: U32, +bad: U32) -> T & U32:
  match xs:
    case Nil{}:
      (t, b) = p
      (t, bad)
    case Con{x, rest}:
      (t, +b) = p
      mcmpl(rest, mrb(U32.add(ga, 1), t), U32.add(ga, 1), U32.add(bad, V.bit(U32.is_ne(b, x))))

# the same for d bytes
def dcmpl(xs: List<&2, U32>, p: T & U32, +b: U32, +bad: U32) -> T & U32:
  match xs:
    case Nil{}:
      (t, v) = p
      (t, bad)
    case Con{x, rest}:
      (t, +v) = p
      dcmpl(rest, drb(U32.add(b, 1), t), U32.add(b, 1), U32.add(bad, V.bit(U32.is_ne(v, x))))

def mcmp(xs: List<&2, U32>, t: T, +ga: U32) -> T & U32:
  mcmpl(xs, mrb(ga, t), ga, 0)

def dcmp(xs: List<&2, U32>, t: T, +b: U32) -> T & U32:
  dcmpl(xs, drb(b, t), b, 0)

def lo8(p: T & U32) -> T & U32:
  (t, +v) = p
  (t, U32.and(v, 255))

# Checks
# ------

def line(+ok: Bool, +name: String, +got: U32, +want: U32) -> String:
  match ok:
    case True{}:
      "PASS " ++ name
    case False{}:
      "FAIL " ++ name ++ ": got " ++ U32.show(got) ++ ", want " ++ U32.show(want)

def chk(+name: String, +ok: Bool, +got: U32, +want: U32, t: T) -> T:
  T{m, d, log, +n, +bad} = t
  T{m, d, line(ok, name, got, want) <> log, U32.add(n, 1), U32.add(bad, V.bit(Bool.not(ok)))}

def ck(+name: String, +want: U32, p: T & U32) -> T:
  (t, +got) = p
  chk(name, U32.is_eq(got, want), got, want, t)

# lists: on failure the lengths are shown
def ckl(+name: String, +want: List<&2, U32>, p: T & List<&2, U32>) -> T:
  (t, +got) = p
  chk(name, leq(got, want), U32.from_nat(List.length(&2, U32, got)), U32.from_nat(List.length(&2, U32, want)), t)

# Virtqueues
# ----------

# descriptor i of the table at dt
def desc(+dt: U32, +i: U32, +a: U32, +l: U32, +f: U32, +nx: U32, t: T) -> T:
  +e = U32.add(dt, U32.shln(i, 4n))
  t = mwr(e, a, t)
  t = mwr(U32.add(e, 4), 0, t)
  t = mwr(U32.add(e, 8), l, t)
  mwr(U32.add(e, 12), U32.or(f, U32.shln(nx, 16n)), t)

# avail ring at av (qs entries): ring[slot] = head, then idx = slot + 1
def post(+av: U32, +qs: U32, +slot: U32, +head: U32, t: T) -> T:
  t = mwh(U32.add(U32.add(av, 4), U32.shln(U32.and(slot, U32.sub(qs, 1)), 1n)), head, t)
  mwh(U32.add(av, 2), U32.and(U32.add(slot, 1), 65535), t)

# used ring at us (8 entries): idx, and the id / len of element pos
def uidx(+us: U32, t: T) -> T & U32:
  mrh(U32.add(us, 2), t)

def uid(+us: U32, +pos: U32, t: T) -> T & U32:
  mrd(U32.add(U32.add(us, 4), U32.shln(U32.and(pos, 7), 3n)), t)

def ulen(+us: U32, +pos: U32, t: T) -> T & U32:
  mrd(U32.add(U32.add(us, 8), U32.shln(U32.and(pos, 7), 3n)), t)

# Linux's order: reset, ACKNOWLEDGE, DRIVER, features (high word, then low), FEATURES_OK
def hello(+base: U32, +lo: U32, t: T) -> T:
  t = wr(at(base, 112), 0, t)
  t = wr(at(base, 112), 1, t)
  t = wr(at(base, 112), 3, t)
  t = wr(at(base, 36), 1, t)
  t = wr(at(base, 32), 1, t)
  t = wr(at(base, 36), 0, t)
  t = wr(at(base, 32), lo, t)
  wr(at(base, 112), 11, t)

# as vm_setup_vq: select, size, the three areas, ready
def qsetup(+base: U32, +q: U32, +num: U32, +dt: U32, +av: U32, +us: U32, t: T) -> T:
  t = wr(at(base, 48), q, t)
  t = wr(at(base, 56), num, t)
  t = wr(at(base, 128), dt, t)
  t = wr(at(base, 132), 0, t)
  t = wr(at(base, 144), av, t)
  t = wr(at(base, 148), 0, t)
  t = wr(at(base, 160), us, t)
  t = wr(at(base, 164), 0, t)
  wr(at(base, 68), 1, t)

# a block request header: type, reserved, sector (u64)
def bhdr(+h: U32, +ty: U32, +s: U32, t: T) -> T:
  t = mwr(h, ty, t)
  t = mwr(U32.add(h, 4), 0, t)
  t = mwr(U32.add(h, 8), s, t)
  mwr(U32.add(h, 12), 0, t)

# a 3-descriptor block request (header, one data buffer, status) at descriptors i..i+2
def breq3(+dt: U32, +i: U32, +h: U32, +ty: U32, +s: U32, +buf: U32, +len: U32, +wflag: U32, +st: U32, t: T) -> T:
  t = bhdr(h, ty, s, t)
  t = mwb(st, 255, t)
  t = desc(dt, i, h, 16, 1, U32.add(i, 1), t)
  t = desc(dt, U32.add(i, 1), buf, len, U32.or(1, wflag), U32.add(i, 2), t)
  desc(dt, U32.add(i, 2), st, 1, 2, 0, t)

# a 2-descriptor block request (header, status)
def breq2(+dt: U32, +i: U32, +h: U32, +ty: U32, +st: U32, t: T) -> T:
  t = bhdr(h, ty, 0, t)
  t = mwb(st, 255, t)
  t = desc(dt, i, h, 16, 1, U32.add(i, 1), t)
  desc(dt, U32.add(i, 1), st, 1, 2, 0, t)

# Block device
# ------------
# queue 0: 8 entries, descriptors at 0x10000, avail 0x10100, used 0x10200

def QD() -> U32:
  65536

def QA() -> U32:
  65792

def QU() -> U32:
  66048

def blk.probe(t: T) -> T:
  t = ck("blk: MagicValue is 'virt'", 1953655158, rd(B(), t))
  t = ck("blk: Version is 2", 2, rd(at(B(), 4), t))
  t = ck("blk: DeviceID is 0 (no device) before a disk is attached", 0, rd(at(B(), 8), t))
  t = attach(t)
  t = ck("blk: DeviceID is 2 once attached", 2, rd(at(B(), 8), t))
  t = ck("blk: VendorID", 1431127377, rd(at(B(), 12), t))
  t = wr(at(B(), 112), 0, t)
  t = ck("blk: Status reads 0 after reset", 0, rd(at(B(), 112), t))
  t = wr(at(B(), 112), 1, t)
  t = wr(at(B(), 112), 3, t)
  t = ck("blk: Status reads ACKNOWLEDGE|DRIVER", 3, rd(at(B(), 112), t))
  t = wr(at(B(), 20), 1, t)
  t = ck("blk: DeviceFeatures[1] = VERSION_1", 1, rd(at(B(), 16), t))
  t = wr(at(B(), 20), 0, t)
  t = ck("blk: DeviceFeatures[0] = 0 (no indirect, no event idx)", 0, rd(at(B(), 16), t))
  t = wr(at(B(), 20), 2, t)
  t = ck("blk: DeviceFeatures[2] = 0", 0, rd(at(B(), 16), t))
  t = wr(at(B(), 36), 1, t)
  t = wr(at(B(), 32), 1, t)
  t = wr(at(B(), 36), 0, t)
  t = wr(at(B(), 32), 0, t)
  t = wr(at(B(), 112), 11, t)
  t = ck("blk: FEATURES_OK sticks", 11, rd(at(B(), 112), t))
  t = wr(at(B(), 48), 1, t)
  t = ck("blk: QueueNumMax of queue 1 is 0", 0, rd(at(B(), 52), t))
  t = ck("blk: QueueReady of queue 1 is 0", 0, rd(at(B(), 68), t))
  t = wr(at(B(), 48), 0, t)
  t = ck("blk: QueueReady of queue 0 is 0 before setup", 0, rd(at(B(), 68), t))
  t = ck("blk: QueueNumMax of queue 0 is 256", 256, rd(at(B(), 52), t))
  t = qsetup(B(), 0, 8, QD(), QA(), QU(), t)
  t = ck("blk: QueueReady reads 1", 1, rd(at(B(), 68), t))
  t = wr(at(B(), 112), 15, t)
  t = ck("blk: DRIVER_OK", 15, rd(at(B(), 112), t))
  t = ck("blk: capacity low word = 128 sectors", 128, rd(at(B(), 256), t))
  t = ck("blk: capacity high word = 0", 0, rd(at(B(), 260), t))
  t = ck("blk: capacity byte read at 0x100", 128, lo8(rd(at(B(), 256), t)))
  t = ck("blk: config past capacity reads 0", 0, rd(at(B(), 276), t))
  t = ck("blk: ConfigGeneration is 0", 0, rd(at(B(), 252), t))
  t = ck("blk: line low after setup", 0, lines(t))
  t

def blk.io(t: T) -> T:
  # IN, sector 1, one aligned 512-byte buffer
  t = breq3(QD(), 0, 131072, 0, 1, 196608, 512, 2, 192512, t)
  t = post(QA(), 8, 0, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk IN aligned: status OK", 0, mrb(192512, t))
  t = ck("blk IN aligned: used.idx = 1", 1, uidx(QU(), t))
  t = ck("blk IN aligned: used id = head 0", 0, uid(QU(), 0, t))
  t = ck("blk IN aligned: used len = 513", 513, ulen(QU(), 0, t))
  t = ck("blk IN aligned: data = sector 1", 0, mcmp(dgen(512n, 1024, Nil{}), t, 196608))
  t = ck("blk IN aligned: InterruptStatus = 1", 1, rd(at(B(), 96), t))
  t = ck("blk IN aligned: line 2 asserted (bit 2)", 4, lines(t))
  t = wr(at(B(), 100), 1, t)
  t = ck("blk InterruptACK clears InterruptStatus", 0, rd(at(B(), 96), t))
  t = ck("blk InterruptACK drops the line", 0, lines(t))
  # OUT, sector 3, data in two unaligned buffers (100 + 412 bytes)
  t = bhdr(131104, 1, 3, t)
  t = mputl(gen(100n, 100, 5, Nil{}), t, 200705)
  t = mputl(gen(412n, 512, 5, Nil{}), t, 204803)
  t = mwb(192513, 255, t)
  t = desc(QD(), 0, 131104, 16, 1, 1, t)
  t = desc(QD(), 1, 200705, 100, 1, 2, t)
  t = desc(QD(), 2, 204803, 412, 1, 3, t)
  t = desc(QD(), 3, 192513, 1, 2, 0, t)
  t = post(QA(), 8, 1, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk OUT 2 unaligned buffers: status OK", 0, mrb(192513, t))
  t = ck("blk OUT: used.idx = 2", 2, uidx(QU(), t))
  t = ck("blk OUT: used len = 1", 1, ulen(QU(), 1, t))
  t = ck("blk OUT: disk sector 3 holds the data", 0, dcmp(gen(512n, 512, 5, Nil{}), t, 4195840))
  t = ck("blk OUT: sector 4 untouched", 0, dcmp(dgen(16n, 2064, Nil{}), t, 4196352))
  t = ck("blk OUT: sector 2 untouched", 0, dcmp(dgen(16n, 1536, Nil{}), t, 4195824))
  # IN, sector 3, into two unaligned buffers (7 + 505 bytes)
  t = bhdr(131136, 0, 3, t)
  t = mwb(192514, 255, t)
  t = desc(QD(), 0, 131136, 16, 1, 1, t)
  t = desc(QD(), 1, 208898, 7, 3, 2, t)
  t = desc(QD(), 2, 212997, 505, 3, 3, t)
  t = desc(QD(), 3, 192514, 1, 2, 0, t)
  t = post(QA(), 8, 2, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk IN 2 unaligned buffers: status OK", 0, mrb(192514, t))
  t = ck("blk IN unaligned: used len = 513", 513, ulen(QU(), 2, t))
  t = ck("blk IN unaligned: first buffer", 0, mcmp(gen(7n, 7, 5, Nil{}), t, 208898))
  t = ck("blk IN unaligned: second buffer", 0, mcmp(gen(505n, 512, 5, Nil{}), t, 212997))
  t = ck("blk IN unaligned: byte before the buffer untouched", 0, mrb(208897, t))
  t = ck("blk IN unaligned: byte after the buffer untouched", 0, mrb(208905, t))
  # GET_ID into a 20-byte unaligned buffer
  t = mputl({[170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170, 170] : List<&2, U32>}, t, 217089)
  t = breq3(QD(), 0, 131168, 8, 0, 217089, 20, 2, 192515, t)
  t = post(QA(), 8, 3, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk GET_ID: status OK", 0, mrb(192515, t))
  t = ck("blk GET_ID: used len = 21", 21, ulen(QU(), 3, t))
  t = ck("blk GET_ID: id is 'wiltee', zero-padded to 20 bytes", 0, mcmp({[119, 105, 108, 116, 101, 101] : List<&2, U32>}, t, 217089))
  t = ck("blk GET_ID: padding", 0, mcmp(zeros(14n, Nil{}), t, 217095))
  t = ck("blk GET_ID: byte after the buffer untouched", 170, mrb(217109, t))
  # two requests in one notify: both out of range
  t = breq3(QD(), 0, 131200, 0, 128, 221184, 512, 2, 192516, t)
  t = breq3(QD(), 3, 131216, 0, 127, 225280, 1024, 2, 192517, t)
  t = post(QA(), 8, 4, 0, t)
  t = post(QA(), 8, 5, 3, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk IN sector 128 of 128: IOERR", 1, mrb(192516, t))
  t = ck("blk IN sectors 127-128: IOERR", 1, mrb(192517, t))
  t = ck("blk batch of 2: used.idx = 6", 6, uidx(QU(), t))
  t = ck("blk batch: used id of the 2nd = head 3", 3, uid(QU(), 5, t))
  t = ck("blk IOERR: used len = 1", 1, ulen(QU(), 4, t))
  t = ck("blk IOERR: nothing written to the buffer", 0, mrd(221184, t))
  # FLUSH, an unsupported type, and the last sector; the ring wraps
  t = breq2(QD(), 0, 131232, 4, 192518, t)
  t = breq2(QD(), 2, 131248, 11, 192519, t)
  t = breq3(QD(), 4, 131264, 0, 127, 229376, 512, 2, 192520, t)
  t = post(QA(), 8, 6, 0, t)
  t = post(QA(), 8, 7, 2, t)
  t = post(QA(), 8, 8, 4, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk FLUSH: status OK", 0, mrb(192518, t))
  t = ck("blk type 11 (DISCARD, not offered): UNSUPP", 2, mrb(192519, t))
  t = ck("blk IN last sector: status OK", 0, mrb(192520, t))
  t = ck("blk ring wrap: used.idx = 9", 9, uidx(QU(), t))
  t = ck("blk ring wrap: used[8 mod 8] id = head 4", 4, uid(QU(), 8, t))
  t = ck("blk ring wrap: used[8 mod 8] len = 513", 513, ulen(QU(), 8, t))
  t = ck("blk IN last sector: data", 0, mcmp(dgen(512n, 65536, Nil{}), t, 229376))
  # NO_INTERRUPT in avail.flags suppresses the interrupt
  t = wr(at(B(), 100), 1, t)
  t = mwh(QA(), 1, t)
  t = breq2(QD(), 0, 131280, 4, 192521, t)
  t = post(QA(), 8, 9, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk NO_INTERRUPT: request completed", 10, uidx(QU(), t))
  t = ck("blk NO_INTERRUPT: InterruptStatus stays 0", 0, rd(at(B(), 96), t))
  t = ck("blk NO_INTERRUPT: line stays low", 0, lines(t))
  t = mwh(QA(), 0, t)
  # 4 KiB aligned OUT then IN (the word-copy path)
  t = mputl(gen(4096n, 4096, 77, Nil{}), t, 262144)
  t = breq3(QD(), 0, 131296, 1, 8, 262144, 4096, 0, 192522, t)
  t = post(QA(), 8, 10, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk OUT 4 KiB: status OK", 0, mrb(192522, t))
  t = ck("blk OUT 4 KiB: disk sectors 8-15", 0, dcmp(gen(4096n, 4096, 77, Nil{}), t, 4198400))
  t = breq3(QD(), 0, 131312, 0, 8, 327680, 4096, 2, 192523, t)
  t = post(QA(), 8, 11, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk IN 4 KiB: status OK", 0, mrb(192523, t))
  t = ck("blk IN 4 KiB: used len = 4097", 4097, ulen(QU(), 11, t))
  t = ck("blk IN 4 KiB: data", 0, mcmp(gen(4096n, 4096, 77, Nil{}), t, 327680))
  t = ck("blk: used.idx = 12", 12, uidx(QU(), t))
  t = ck("blk: line asserted again", 4, lines(t))
  t

# Status = 0 resets the device; the disk survives and the driver starts over
# with fresh rings (descriptors 0x14000, avail 0x14100, used 0x14200).
def blk.reset(t: T) -> T:
  t = wr(at(B(), 112), 0, t)
  t = ck("blk reset: Status = 0", 0, rd(at(B(), 112), t))
  t = ck("blk reset: QueueReady = 0", 0, rd(at(B(), 68), t))
  t = ck("blk reset: InterruptStatus = 0", 0, rd(at(B(), 96), t))
  t = ck("blk reset: line low", 0, lines(t))
  t = ck("blk reset: capacity kept", 128, rd(at(B(), 256), t))
  t = hello(B(), 0, t)
  t = qsetup(B(), 0, 8, 81920, 82176, 82432, t)
  t = wr(at(B(), 112), 15, t)
  t = breq3(81920, 0, 131328, 0, 0, 233472, 512, 2, 192524, t)
  t = post(82176, 8, 0, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("blk after reset: IN status OK", 0, mrb(192524, t))
  t = ck("blk after reset: used.idx = 1", 1, uidx(82432, t))
  t = ck("blk after reset: used len = 513", 513, ulen(82432, 0, t))
  t = ck("blk after reset: data = sector 0", 0, mcmp(dgen(512n, 512, Nil{}), t, 233472))
  wr(at(B(), 100), 1, t)

# Network device
# --------------
# receive queue 0: descriptors 0x12000, avail 0x12100, used 0x12200;
# transmit queue 1: descriptors 0x13000, avail 0x13100, used 0x13200

def RD() -> U32:
  73728

def RA() -> U32:
  73984

def RU() -> U32:
  74240

def TD() -> U32:
  77824

def TA() -> U32:
  78080

def TU() -> U32:
  78336

def net.probe(t: T) -> T:
  t = ck("net: MagicValue", 1953655158, rd(N(), t))
  t = ck("net: Version is 2", 2, rd(at(N(), 4), t))
  t = ck("net: DeviceID is 1", 1, rd(at(N(), 8), t))
  t = wr(at(N(), 20), 0, t)
  t = ck("net: DeviceFeatures[0] = MAC (bit 5)", 32, rd(at(N(), 16), t))
  t = wr(at(N(), 20), 1, t)
  t = ck("net: DeviceFeatures[1] = VERSION_1", 1, rd(at(N(), 16), t))
  t = ck("net: config mac[0..3] = 52:54:00:12", 302011474, rd(at(N(), 256), t))
  t = ck("net: config mac[4..5] = 34:56 by default", 22068, rd(at(N(), 260), t))
  t = ck("net: byte read of mac[1]", 84, lo8(rd(at(N(), 257), t)))
  t = ck("net: byte read of mac[5]", 86, lo8(rd(at(N(), 261), t)))
  t = setmac(7, t)
  t = ck("net: mac[5] = 07 after net.mac(7)", 7, lo8(rd(at(N(), 261), t)))
  t = ck("net: config mac[4..5] = 34:07", 1844, rd(at(N(), 260), t))
  t = ck("net: config past the MAC reads 0", 0, rd(at(N(), 262), t))
  t = ck("net: ConfigGeneration is 0", 0, rd(at(N(), 252), t))
  t = ck("net: SHMLenLow is -1 (no shared memory)", 4294967295, rd(at(N(), 176), t))
  t = hello(N(), 32, t)
  t = ck("net: FEATURES_OK sticks", 11, rd(at(N(), 112), t))
  t = wr(at(N(), 48), 2, t)
  t = ck("net: QueueNumMax of queue 2 is 0", 0, rd(at(N(), 52), t))
  t = wr(at(N(), 48), 1, t)
  t = ck("net: QueueNumMax of queue 1 is 256", 256, rd(at(N(), 52), t))
  t = qsetup(N(), 0, 8, RD(), RA(), RU(), t)
  t = qsetup(N(), 1, 8, TD(), TA(), TU(), t)
  t = ck("net: QueueReady of queue 1", 1, rd(at(N(), 68), t))
  t = wr(at(N(), 48), 0, t)
  t = ck("net: QueueReady of queue 0", 1, rd(at(N(), 68), t))
  t = wr(at(N(), 112), 15, t)
  t = ck("net: DRIVER_OK", 15, rd(at(N(), 112), t))
  t

def net.tx(t: T) -> T:
  # frame A: header in its own descriptor, 60 bytes of frame in the next
  t = mputl(zeros(12n, Nil{}), t, 393216)
  t = mputl(gen(60n, 60, 3, Nil{}), t, 393474)
  t = desc(TD(), 0, 393216, 12, 1, 1, t)
  t = desc(TD(), 1, 393474, 60, 0, 0, t)
  # frame B: header and 42 bytes in one unaligned descriptor
  t = mputl(zeros(12n, gen(42n, 42, 9, Nil{})), t, 397313)
  t = desc(TD(), 2, 397313, 54, 0, 0, t)
  t = post(TA(), 8, 0, 0, t)
  t = post(TA(), 8, 1, 2, t)
  t = wr(at(N(), 80), 1, t)
  t = ck("net TX: used.idx = 2", 2, uidx(TU(), t))
  t = ck("net TX: used id of frame B = head 2", 2, uid(TU(), 1, t))
  t = ck("net TX: used len = 0", 0, ulen(TU(), 0, t))
  t = ck("net TX: InterruptStatus = 1", 1, rd(at(N(), 96), t))
  t = ck("net TX: line 3 asserted (bit 3)", 8, lines(t))
  t = ckl("net TX: net.take = both frames, headers stripped", enc(60, 3, enc(42, 9, Nil{})), take(t))
  t = ckl("net TX: a second net.take is empty", Nil{}, take(t))
  t = ck("net TX: transmit buffer drained", 0, drd(1291, t))
  t = wr(at(N(), 100), 1, t)
  t = ck("net InterruptACK drops the line", 0, lines(t))
  t

def net.rx(t: T) -> T:
  # buffer A: one descriptor at 2 mod 4, as Linux posts them (12 + 1514)
  t = desc(RD(), 0, 458754, 1526, 2, 0, t)
  # buffer B: 8 bytes, then 1600 unaligned bytes (the header spans both)
  t = desc(RD(), 1, 462848, 8, 3, 2, t)
  t = desc(RD(), 2, 463105, 1600, 2, 0, t)
  t = post(RA(), 8, 0, 0, t)
  t = post(RA(), 8, 1, 1, t)
  t = wr(at(N(), 80), 0, t)
  t = ck("net RX: posting buffers with no frame waiting completes nothing", 0, uidx(RU(), t))
  t = ck("net RX: no interrupt", 0, rd(at(N(), 96), t))
  t = give(enc(64, 11, enc(100, 12, enc(30, 13, Nil{}))), t)
  t = ck("net RX: net.give queues 3 frames (tail)", 240, drd(1293, t))
  t = ck("net RX: poll delivers 2 frames into 2 buffers", 2, poll(t))
  t = ck("net RX: used.idx = 2", 2, uidx(RU(), t))
  t = ck("net RX: used id of buffer A", 0, uid(RU(), 0, t))
  t = ck("net RX: used len = 12 + 64", 76, ulen(RU(), 0, t))
  t = ck("net RX: used id of buffer B", 1, uid(RU(), 1, t))
  t = ck("net RX: used len = 12 + 100", 112, ulen(RU(), 1, t))
  t = ck("net RX: buffer A = header (num_buffers 1) + frame", 0, mcmp(hdr(gen(64n, 64, 11, Nil{})), t, 458754))
  t = ck("net RX: buffer B, first descriptor = header bytes 0-7", 0, mcmp(zeros(8n, Nil{}), t, 462848))
  t = ck("net RX: buffer B, second descriptor = header bytes 8-11 + frame", 0, mcmp({[0, 0, 1, 0] : List<&2, U32>}, t, 463105))
  t = ck("net RX: buffer B frame", 0, mcmp(gen(100n, 100, 12, Nil{}), t, 463109))
  t = ck("net RX: byte after frame B untouched", 0, mrb(463209, t))
  t = ck("net RX: InterruptStatus = 1", 1, rd(at(N(), 96), t))
  t = ck("net RX: line 3 asserted", 8, lines(t))
  t = ck("net RX: the 3rd frame waits for a buffer", 0, poll(t))
  # posting a buffer delivers the waiting frame at once (QueueNotify 0)
  t = desc(RD(), 3, 466944, 1526, 2, 0, t)
  t = post(RA(), 8, 2, 3, t)
  t = wr(at(N(), 80), 0, t)
  t = ck("net RX on notify: used.idx = 3", 3, uidx(RU(), t))
  t = ck("net RX on notify: used len = 12 + 30", 42, ulen(RU(), 2, t))
  t = ck("net RX on notify: buffer C", 0, mcmp(hdr(gen(30n, 30, 13, Nil{})), t, 466944))
  t = ck("net RX: drained buffer rewinds (head)", 0, drd(1292, t))
  t = ck("net RX: drained buffer rewinds (tail)", 0, drd(1293, t))
  # a frame too big for the posted buffer is dropped; the buffer takes the next
  t = give(enc(1600, 14, enc(20, 15, Nil{})), t)
  t = desc(RD(), 4, 471040, 1526, 2, 0, t)
  t = post(RA(), 8, 3, 4, t)
  t = ck("net RX oversized: poll delivers 1", 1, poll(t))
  t = ck("net RX oversized: used.idx = 4", 4, uidx(RU(), t))
  t = ck("net RX oversized: used id", 4, uid(RU(), 3, t))
  t = ck("net RX oversized: the next frame went in (len 12 + 20)", 32, ulen(RU(), 3, t))
  t = ck("net RX oversized: buffer D", 0, mcmp(hdr(gen(20n, 20, 15, Nil{})), t, 471040))
  # 90 frames of 1500 bytes: 86 fit the 128 KiB buffer, the rest are dropped
  t = give(many(90n, Nil{}), t)
  t = ck("net RX full: 86 records of 1516 bytes kept", 130376, drd(1293, t))
  t = ck("net RX full: no buffer posted, nothing delivered", 0, poll(t))
  t

def net.reset(t: T) -> T:
  # both lines at once
  t = breq2(81920, 0, 131344, 4, 192525, t)
  t = post(82176, 8, 1, 0, t)
  t = wr(at(B(), 80), 0, t)
  t = ck("lines: block and network both asserted", 12, lines(t))
  t = wr(at(N(), 100), 1, t)
  t = ck("lines: network acknowledged, block still asserted", 4, lines(t))
  t = wr(at(B(), 100), 1, t)
  t = ck("lines: both acknowledged", 0, lines(t))
  t = wr(at(N(), 112), 0, t)
  t = ck("net reset: Status = 0", 0, rd(at(N(), 112), t))
  t = ck("net reset: QueueReady of queue 0 = 0", 0, rd(at(N(), 68), t))
  t = wr(at(N(), 48), 1, t)
  t = ck("net reset: QueueReady of queue 1 = 0", 0, rd(at(N(), 68), t))
  t = ck("net reset: MAC kept", 7, lo8(rd(at(N(), 261), t)))
  t = ck("net reset: poll delivers nothing to a reset device", 0, poll(t))
  t = ck("net reset: waiting frames kept", 130376, drd(1293, t))
  # the driver comes back with fresh rings and gets a waiting frame
  t = hello(N(), 32, t)
  t = qsetup(N(), 0, 8, 86016, 86272, 86528, t)
  t = wr(at(N(), 112), 15, t)
  t = desc(86016, 0, 475138, 1526, 2, 0, t)
  t = post(86272, 8, 0, 0, t)
  t = ck("net after reset: poll delivers 1", 1, poll(t))
  t = ck("net after reset: used.idx = 1", 1, uidx(86528, t))
  t = ck("net after reset: used len = 12 + 1500", 1512, ulen(86528, 0, t))
  t = ck("net after reset: buffer", 0, mcmp(hdr(gen(1500n, 1500, 21, Nil{})), t, 475138))
  t = ck("net after reset: next record is at the head", 1516, drd(1292, t))
  # net.give moves the waiting records to the front, making room for one more
  t = give(enc(1500, 22, Nil{}), t)
  t = ck("net RX compaction: head back at 0", 0, drd(1292, t))
  t = ck("net RX compaction: 85 old + 1 new records", 130376, drd(1293, t))
  t = desc(86016, 1, 479234, 1526, 2, 0, t)
  t = post(86272, 8, 1, 1, t)
  t = ck("net RX compaction: poll delivers 1", 1, poll(t))
  t = ck("net RX compaction: used len = 12 + 1500", 1512, ulen(86528, 1, t))
  t = ck("net RX compaction: moved frame intact", 0, mcmp(hdr(gen(1500n, 1500, 21, Nil{})), t, 479234))
  t

# Report
# ------

def plines(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{x, rest}:
      do IO<Unit>:
        IO.print(x)
        plines(rest)

def summary(+n: U32, +bad: U32) -> String:
  "virtio: " ++ U32.show(U32.sub(n, bad)) ++ "/" ++ U32.show(n) ++ " checks passed"

def report(t: T) -> IO(Unit):
  T{m, d, log, +n, +bad} = t
  do IO<Unit>:
    plines(List.reverse(&1, String, log))
    IO.print(summary(n, bad))
    IO.exit(V.bit(V.nz(bad)))

def main() -> IO(Unit):
  report(net.reset(net.rx(net.tx(net.probe(blk.reset(blk.io(blk.probe(T{[0 : U32^20n], [0 : U32^21n], Nil{}, 0, 0}))))))))
