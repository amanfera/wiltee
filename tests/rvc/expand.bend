import Base
import ../../src/rvc.bend as R

# Prints "<halfword> <expansion>" in hex for every halfword with its low two
# bits not 0b11 (the 49,152 RV64C encodings), in ascending order.
# Usage: expand

def sel(+c: Bool, +a: U32, +b: U32) -> U32:
  match c:
    case True{}:
      a
    case False{}:
      b

def hex.digit(+d: U32) -> Char:
  Chr{sel(U32.is_lt(d, 10), U32.add(d, 48), U32.add(d, 87))}

# n hex digits of x, most significant first
def hex(+x: U32, +n: Nat) -> String:
  match n:
    case 0n:
      SNil{}
    case 1n+p:
      SCon{hex.digit(U32.and(U32.shrn(x, Nat.mul(4n, p)), 15)), hex(x, p)}

def line(+h: U32) -> String:
  hex(h, 4n) ++ " " ++ hex(R.C.expand(h), 8n)

def emit.go(+skip: Bool, +h: U32) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print(line(h))

def emit(+h: U32) -> IO(Unit):
  emit.go(U32.is_eq(U32.and(h, 3), 3), h)

# k halfwords left, starting at h
def sweep(+k: Nat, +h: U32) -> IO(Unit):
  match k:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        emit(h)
        sweep(p, U32.add(h, 1))

def main() -> IO(Unit):
  sweep(65536n, 0)
