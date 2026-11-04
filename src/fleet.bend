import Base
import ./hart.bend as H

# fleet: runs 2^d independent machines, all from one boot image, each told
# its id in a0. Every epoch is one call `H.Fleet.epoch!`: a fork tree with a
# machine per leaf, on the GPU when there is one (else on the CPU pool).
# Usage: fleet <image> <d>

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
      H.VM{H.Hart.new(load.put(bs, [0 : U32*33554432n], 0), id, 0, 0)}
    case 1n+p:
      a b = build(p, bs, U32.shln(id, 1n)) build(p, bs, U32.add(U32.shln(id, 1n), 1))
      H.Two{a, b}

# One epoch for every machine, then their consoles and counts.
def turn(f: H.Fleet) -> H.Tally:
  H.Fleet.tally(H.Fleet.epoch!(1000000n, 2000000, f))

def bytes.str(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, rest}:
      SCon{Chr{b}, bytes.str(rest)}

@unsafe
def loop(k: Nat, f: H.Fleet, +t0: Nat) -> IO(Unit):
  match k:
    case 0n:
      IO.print("fleet: epoch limit")
    case 1n+p:
      loop.k(p, t0, turn(f))

@unsafe
def loop.k(k: Nat, +t0: Nat, r: H.Tally) -> IO(Unit):
  H.Tally{f, +live, +lo, out} = r
  do IO<Unit>:
    IO.write(bytes.str(out))
    loop.end(U32.is_zero(live), k, f, lo, t0)

# lo: instructions retired by all machines so far
@unsafe
def loop.end(done: Bool, k: Nat, f: H.Fleet, +lo: U32, +t0: Nat) -> IO(Unit):
  match done:
    case False{}:
      loop(k, f, t0)
    case True{}:
      do IO<Unit>:
        t1 : Nat <- IO.now()
        IO.print("fleet: " ++ U32.show(lo) ++ " guest instructions in " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms")

@unsafe
def go.k(+d: Nat, path: String, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  (f, res) = r
  go.res(res, f, d, path)

@unsafe
def go.res(res: Result<&1, &1, U32 & String, List<&2, U32>>, f: File, +d: Nat, path: String) -> IO(Unit):
  match res:
    case Done{bs}:
      do IO<Unit>:
        File.close(f)
        t0 : Nat <- IO.now()
        loop(100000n, build(d, bs, 0), t0)
    case Fail{e}:
      do IO<Unit>:
        File.close(f)
        IO.print("fleet: cannot read " ++ path)

@unsafe
def go(+path: String, d: Nat) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 1048576)
    go.k(d, path, r)

@unsafe
def main.d(path: String, d: Maybe<&2, U32>) -> IO(Unit):
  match d:
    case Some{n}:
      go(path, U32.to_nat(n))
    case None{}:
      IO.print("usage: fleet <image> <d>  (runs 2^d machines)")

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{path, Con{d, Nil{}}}}:
      main.d(path, U32.read(d))
    case _:
      IO.print("usage: fleet <image> <d>  (runs 2^d machines)")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
