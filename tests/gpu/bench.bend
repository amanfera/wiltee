import Base
import ../../src/hart.bend as H

# GPU bring-up benchmark: 2^d machines (64 KiB RAM each) booted from one
# image; times three successive epochs of `budget` guest instructions, run
# as one bang each (on the GPU when there is one), then the same on the CPU
# pool. Usage: bench <image> <d> <budget>

def load.put(bs: List<&2, U32>, m: Array<U32>, +a: U32) -> Array<U32>:
  match bs:
    case Con{b0, Con{b1, Con{b2, Con{b3, rest}}}}:
      m[U32.shrn(a, 2n)] <- U32.or(U32.or(b0, U32.shln(b1, 8n)), U32.or(U32.shln(b2, 16n), U32.shln(b3, 24n)))
      load.put(rest, m, U32.add(a, 4))
    case _:
      m

def build(+d: Nat, +bs: List<&2, U32>, +id: U32) -> H.Fleet:
  match d:
    case 0n:
      H.VM{H.Hart.new(load.put(bs, [0 : U32*16384n], 0), id, 0, 0)}
    case 1n+p:
      a b = build(p, bs, U32.shln(id, 1n)) build(p, bs, U32.add(U32.shln(id, 1n), 1))
      H.Two{a, b}

def gpu(+budget: U32, f: H.Fleet) -> H.Fleet:
  H.Fleet.epoch!(4n, budget, f)

def cpu(+budget: U32, f: H.Fleet) -> H.Fleet:
  H.Fleet.epoch(4n, budget, f)

def count(r: H.Tally) -> U32:
  H.Tally{f, live, lo, out} = r
  lo

def rate(+n: U32, +ms: Nat) -> String:
  U32.show(n) ++ " guest instrs in " ++ Nat.show(ms) ++ " ms"

def ms(+a: Nat, +b: Nat) -> String:
  Nat.show(Nat.sub(b, a)) ++ " ms"

@unsafe
def fin(+t: Nat, f: H.Fleet) -> IO(Unit):
  do IO<Unit>:
    t2 : Nat <- IO.now()
    IO.print("cpu pool: " ++ ms(t, t2) ++ "; total retired " ++ U32.show(count(H.Fleet.tally(f))))

@unsafe
def cpu.step(+budget: U32, f: H.Fleet) -> IO(Unit):
  do IO<Unit>:
    t : Nat <- IO.now()
    fin(t, cpu(budget, f))

@unsafe
def bang(+k: Nat, +budget: U32, +t: Nat, f: H.Fleet) -> IO(Unit):
  match k:
    case 0n:
      cpu.step(budget, f)
    case 1n+p:
      bang.k(p, budget, t, gpu(budget, f))

@unsafe
def bang.p(+k: Nat, +budget: U32, +t: Nat, +t2: Nat, f: H.Fleet) -> IO(Unit):
  do IO<Unit>:
    IO.print("bang: " ++ ms(t, t2))
    bang(k, budget, t2, f)

@unsafe
def bang.k(+k: Nat, +budget: U32, +t: Nat, f: H.Fleet) -> IO(Unit):
  do IO<Unit>:
    t2 : Nat <- IO.now()
    bang.p(k, budget, t, t2, f)

@unsafe
def go(+budget: U32, f: H.Fleet) -> IO(Unit):
  do IO<Unit>:
    t : Nat <- IO.now()
    bang(3n, budget, t, f)

@unsafe
def start(bs: List<&2, U32>, d: Maybe<&2, U32>, b: Maybe<&2, U32>) -> IO(Unit):
  match d b:
    case Some{+dv} Some{+bv}:
      do IO<Unit>:
        IO.print("machines: " ++ U32.show(U32.shln(1, U32.to_nat(dv))) ++ ", budget " ++ U32.show(bv))
        go(bv, build(U32.to_nat(dv), bs, 0))
    case _ _:
      IO.print("usage: bench <image> <d> <budget>")

@unsafe
def read.k(d: String, b: String, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  (f, res) = r
  match res:
    case Done{bs}:
      do IO<Unit>:
        File.close(f)
        start(bs, U32.read(d), U32.read(b))
    case Fail{e}:
      do IO<Unit>:
        File.close(f)
        IO.print("bench: cannot read image")

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{path, Con{d, Con{b, Nil{}}}}}:
      do IO<Unit>:
        f : File <- IO.try(File, File.open(path, "r"))
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
        read.k(d, b, r)
    case _:
      IO.print("usage: bench <image> <d> <budget>")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
