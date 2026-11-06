import Base
import ./hart64.bend as H

# fleet64: runs 2^d independent RV64 machines from one boot image, each told
# its id in a1 (64 KiB of RAM and a small device array each).
#   fleet64 <image> <d> run    the whole run is one call H.Fleet.run!: a single
#                              GPU bang loops over epochs until every machine
#                              has powered off; the host only prints at the end
#   fleet64 <image> <d> step   one bang per epoch, the host drains the consoles
#                              in between (the host-in-the-loop baseline)
# Add +RTS --gpu 1GB -RTS on a CUDA box (see tests/gpu/sweep64.sh).

def load.put(bs: List<&2, U32>, m: Array<U32>, +a: U32) -> Array<U32>:
  match bs:
    case Con{b0, Con{b1, Con{b2, Con{b3, rest}}}}:
      m[U32.shrn(a, 2n)] <- U32.or(U32.or(b0, U32.shln(b1, 8n)), U32.or(U32.shln(b2, 16n), U32.shln(b3, 24n)))
      load.put(rest, m, U32.add(a, 4))
    case Con{b0, Con{b1, Con{b2, Nil{}}}}:
      m[U32.shrn(a, 2n)] <- U32.or(U32.or(b0, U32.shln(b1, 8n)), U32.shln(b2, 16n))
      m
    case Con{b0, Con{b1, Nil{}}}:
      m[U32.shrn(a, 2n)] <- U32.or(b0, U32.shln(b1, 8n))
      m
    case Con{b0, Nil{}}:
      m[U32.shrn(a, 2n)] <- b0
      m
    case Nil{}:
      m

def build(+d: Nat, +bs: List<&2, U32>, +id: U32) -> H.Fleet:
  match d:
    case 0n:
      H.VM{H.Mach.new(load.put(bs, [0 : U32*16384n], 0), 13n, 1, id, 0)}
    case 1n+p:
      a b = build(p, bs, U32.shln(id, 1n)) build(p, bs, U32.add(U32.shln(id, 1n), 1))
      H.Two{a, b}

def budget() -> U32:
  1000000

def bytes.str(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, rest}:
      SCon{Chr{b}, bytes.str(rest)}

def ms(+a: Nat, +b: Nat) -> String:
  Nat.show(Nat.sub(b, a)) ++ " ms"

@unsafe
def report(+t0: Nat, +bangs: Nat, r: H.Tally) -> IO(Unit):
  H.Tally{f, +live, lo, out} = r
  do IO<Unit>:
    t1 : Nat <- IO.now()
    IO.write(bytes.str(out))
    IO.print("fleet64: " ++ Nat.show(bangs) ++ " bang(s), " ++ U32.show(live) ++ " machine(s) still running, " ++ ms(t0, t1))

# step: one bang per epoch until every machine has stopped.
@unsafe
def step.loop(k: Nat, +t0: Nat, +bangs: Nat, f: H.Fleet) -> IO(Unit):
  match k:
    case 0n:
      report(t0, bangs, H.Fleet.tally(f))
    case 1n+p:
      step.k(p, t0, bangs, H.Fleet.tally(H.Fleet.epoch!(1000000n, budget(), f)))

@unsafe
def step.k(k: Nat, +t0: Nat, +bangs: Nat, r: H.Tally) -> IO(Unit):
  H.Tally{f, +live, lo, out} = r
  do IO<Unit>:
    IO.write(bytes.str(out))
    step.end(U32.is_zero(live), k, t0, Nat.add(bangs, 1n), f)

@unsafe
def step.end(done: Bool, k: Nat, +t0: Nat, +bangs: Nat, f: H.Fleet) -> IO(Unit):
  match done:
    case False{}:
      step.loop(k, t0, bangs, f)
    case True{}:
      report(t0, bangs, H.Fleet.tally(f))

@unsafe
def go.mode(+run: Bool, f: H.Fleet) -> IO(Unit):
  match run:
    case True{}:
      do IO<Unit>:
        t0 : Nat <- IO.now()
        report(t0, 1n, H.Fleet.tally(H.Fleet.run!(100000n, budget(), f)))
    case False{}:
      do IO<Unit>:
        t0 : Nat <- IO.now()
        step.loop(100000n, t0, 0n, f)

@unsafe
def go.res(res: Result<&1, &1, U32 & String, List<&2, U32>>, f: File, +d: Nat, +run: Bool, path: String) -> IO(Unit):
  match res:
    case Done{bs}:
      do IO<Unit>:
        File.close(f)
        go.mode(run, build(d, bs, 0))
    case Fail{e}:
      do IO<Unit>:
        File.close(f)
        IO.print("fleet64: cannot read " ++ path)

@unsafe
def go.k(+d: Nat, +run: Bool, path: String, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  (f, res) = r
  go.res(res, f, d, run, path)

@unsafe
def go(+path: String, d: Nat, +run: Bool) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
    go.k(d, run, path, r)

@unsafe
def main.d(path: String, d: Maybe<&2, U32>, mode: String) -> IO(Unit):
  match d:
    case Some{n}:
      go(path, U32.to_nat(n), String.eq(mode, "run"))
    case None{}:
      IO.print("usage: fleet64 <image> <d> run|step  (runs 2^d machines)")

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{path, Con{d, Con{mode, Nil{}}}}}:
      main.d(path, U32.read(d), mode)
    case _:
      IO.print("usage: fleet64 <image> <d> run|step  (runs 2^d machines)")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
