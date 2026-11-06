import Base
import ./hart64.bend as H

# cow64: copy-on-write snapshot fleets. Boots one RV64 Linux guest until its
# shell prompt, snapshots it, and forks it N times: the forks share the
# snapshot's RAM and own only the pages they touch (a pool of 2^pd words
# each). Fork i is given its own command line, then all forks run as one
# call, `H.Snap.run!` (a single GPU bang with +RTS --gpu ...), until each
# has powered off; misses are served from the snapshot between epochs.
# Usage: cow64 <kernel> <dtb> <forks> [pd]   (the dtb must boot to a "# " prompt)

def dtb.at() -> U32:
  133169152

def load.byte(+a: U32, +b: U32, p: Array<U32> & U32) -> Array<U32>:
  (m, +w) = p
  +sh = U32.to_nat(U32.shln(U32.and(a, 3), 3n))
  m[U32.shrn(a, 2n)] <- U32.or(U32.and(w, U32.not(U32.shln(255, sh))), U32.shln(b, sh))
  m

def load.put(bs: List<&2, U32>, m: Array<U32>, +a: U32) -> Array<U32>:
  match bs:
    case Con{b0, Con{b1, Con{b2, Con{b3, rest}}}}:
      m[U32.shrn(a, 2n)] <- U32.or(U32.or(b0, U32.shln(b1, 8n)), U32.or(U32.shln(b2, 16n), U32.shln(b3, 24n)))
      load.put(rest, m, U32.add(a, 4))
    case Con{b, rest}:
      load.put(rest, load.byte(a, b, Array.get(U32, m, U32.shrn(a, 2n))), U32.add(a, 1))
    case Nil{}:
      m

@unsafe
def load.file(+path: String, m: Array<U32>, +a: U32) -> IO(Array<U32>):
  do IO<Array<U32>>:
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 33554432)
    load.k(m, a, path, r)

@unsafe
def load.k(m: Array<U32>, +a: U32, +path: String, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Array<U32>):
  (f, res) = r
  match res:
    case Done{bs}:
      do IO<Array<U32>>:
        File.close(f)
        return load.put(bs, m, a)
    case Fail{e}:
      do IO<Array<U32>>:
        File.close(f)
        IO.die(Array<U32>, 1, "cow64: cannot read " ++ path)

def bytes.str(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, rest}:
      SCon{Chr{b}, bytes.str(rest)}

def str.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, rest}:
      c <> str.bytes(rest)

def tail.fold(bs: List<&2, U32>, +tl: U32) -> U32:
  match bs:
    case Nil{}:
      tl
    case Con{b, rest}:
      tail.fold(rest, U32.or(U32.shln(tl, 8n), b))

# The command fork i runs.
def cmd(+i: U32) -> List<&2, U32>:
  str.bytes("echo fork-" ++ U32.show(i) ++ " $((" ++ U32.show(i) ++ "*" ++ U32.show(i) ++ ")); poweroff -f\n")

def forks.go(k: Nat, +i: U32, +pd: Nat, r: H.MF, acc: List<H.Mach>) -> H.Snap:
  match k:
    case 0n:
      H.MF{a, b} = r
      H.Snap.of(H.Mach.ram(a), List.reverse(&1, H.Mach, H.Mach.feed(cmd(i), b) <> acc))
    case 1n+p:
      H.MF{a, b} = r
      forks.go(p, U32.add(i, 1), pd, H.Mach.fork(a, pd), H.Mach.feed(cmd(i), b) <> acc)

def ms(+a: Nat, +b: Nat) -> String:
  Nat.show(Nat.sub(b, a)) ++ " ms"

# Per fork: its console, then a summary line.
@unsafe
def report.one(+i: U32, r: H.Mach & List<&2, U32>, rest: List<H.Mach>, +pages: Nat) -> IO(Unit):
  (mc, bs) = r
  do IO<Unit>:
    IO.write(bytes.str(bs))
    report.pool(i, H.Mach.pool(mc), rest, pages)

@unsafe
def report.pool(+i: U32, r: H.Mach & U32, rest: List<H.Mach>, +pages: Nat) -> IO(Unit):
  (mc, +pg) = r
  do IO<Unit>:
    IO.print("[cow64] fork " ++ U32.show(i) ++ ": " ++ U32.show(pg) ++ " private pages (" ++ U32.show(U32.shrn(pg, 8n)) ++ " MiB)")
    report(U32.add(i, 1), rest, Nat.add(pages, U32.to_nat(pg)))

@unsafe
def report(+i: U32, ms: List<H.Mach>, +pages: Nat) -> IO(Unit):
  match ms:
    case Nil{}:
      IO.print("[cow64] " ++ U32.show(i) ++ " forks own " ++ Nat.show(pages) ++ " pages (" ++ Nat.show(Nat.div(pages, 256n)) ++ " MiB) in all; full copies would take " ++ U32.show(U32.mul(i, 128)) ++ " MiB")
    case Con{mc, rest}:
      report.one(i, H.Mach.drain(mc), rest, pages)

@unsafe
def fork.all(+n: Nat, +pd: Nat, mc: H.Mach) -> IO(Unit):
  do IO<Unit>:
    IO.print("\n[cow64] snapshot taken at the prompt; forking " ++ Nat.show(n) ++ " machines (pool 2^" ++ Nat.show(pd) ++ " words each)")
    t0 : Nat <- IO.now()
    sp : H.Snap = H.Snap.run!(200000n, 1000000, forks.go(Nat.sub(n, 1n), 0, pd, H.Mach.fork(mc, pd), Nil{}))
    t1 : Nat <- IO.now()
    IO.print("[cow64] all forks ran in one call: " ++ ms(t0, t1))
    report(0, H.Fleet.list(H.Snap.fleet(sp)), 0n)

# Boot: one epoch at a time until the console shows "# ".
@unsafe
def boot.loop(k: Nat, +n: Nat, +pd: Nat, +tl: U32, mc: H.Mach) -> IO(Unit):
  match k:
    case 0n:
      IO.print("cow64: no shell prompt")
    case 1n+p:
      boot.out(p, n, pd, tl, H.Mach.drain(H.Mach.epoch(1000000n, H.Mach.arm(1000000, mc))))

@unsafe
def boot.out(k: Nat, +n: Nat, +pd: Nat, +tl: U32, r: H.Mach & List<&2, U32>) -> IO(Unit):
  (mc, +bs) = r
  do IO<Unit>:
    IO.write(bytes.str(bs))
    boot.next(U32.is_eq(U32.and(tail.fold(bs, tl), 65535), 8992), k, n, pd, tail.fold(bs, tl), mc)

@unsafe
def boot.next(at: Bool, k: Nat, +n: Nat, +pd: Nat, +tl: U32, mc: H.Mach) -> IO(Unit):
  match at:
    case True{}:
      fork.all(n, pd, mc)
    case False{}:
      boot.loop(k, n, pd, tl, mc)

@unsafe
def start(kernel: String, dtb: String, +n: Nat, +pd: Nat) -> IO(Unit):
  do IO<Unit>:
    m1 : Array<U32> <- load.file(kernel, [0 : U32*33554432n], 0)
    m2 : Array<U32> <- load.file(dtb, m1, dtb.at())
    boot.loop(100000n, n, pd, 0, H.Mach.new(m2, 15n, 1, dtb.at(), 0))

@unsafe
def main.n(kernel: String, dtb: String, n: Maybe<&2, U32>, pd: Maybe<&2, U32>) -> IO(Unit):
  match n pd:
    case Some{+k} Some{+p}:
      start(kernel, dtb, U32.to_nat(k), U32.to_nat(p))
    case Some{+k} None{}:
      start(kernel, dtb, U32.to_nat(k), 21n)
    case _ _:
      IO.print("usage: cow64 <kernel> <dtb> <forks> [pd]")

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{kernel, Con{dtb, Con{n, Nil{}}}}}:
      main.n(kernel, dtb, U32.read(n), None{})
    case Con{_, Con{kernel, Con{dtb, Con{n, Con{pd, Nil{}}}}}}:
      main.n(kernel, dtb, U32.read(n), U32.read(pd))
    case _:
      IO.print("usage: cow64 <kernel> <dtb> <forks> [pd]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
