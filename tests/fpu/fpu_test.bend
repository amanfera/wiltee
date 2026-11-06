import Base
import ../../src/fpu.bend as FP

# Checks src/fpu.bend against test vectors in testfloat_gen's format, read
# from stdin: one case per line, hex fields separated by spaces: the
# operands, the expected result, the expected flags.
#
#   fpu_test <function> <rm>     e.g.  testfloat_gen ... f32_add | fpu_test f32_add 0
#
# Prints "RESULT <function> <rm> <passed> <failed>", and the first failing
# case with what src/fpu.bend computed.

# The line being read: fields 0..4 as word pairs, the field count, and the
# hex accumulator of the current field.
type L is Data:
  L{n: U32, ah: U32, al: U32, a0: U32, b0: U32, a1: U32, b1: U32, a2: U32, b2: U32, a3: U32, b3: U32, a4: U32, b4: U32}

# Counters and the first failing case (its fields and our result).
type C is Data:
  C{pass: U32, fail: U32, a0: U32, b0: U32, a1: U32, b1: U32, a2: U32, b2: U32, a3: U32, b3: U32, a4: U32, b4: U32, rh: U32, rl: U32, rf: U32}

type PS is Data:
  PS{l: L, c: C}

def names() -> List<&2, String>:
  ["f32_add", "f32_sub", "f32_mul", "f32_div", "f32_sqrt", "f32_mulAdd", "f32_eq", "f32_lt", "f32_le", "f32_to_i32", "f32_to_ui32", "f32_to_i64", "f32_to_ui64", "i32_to_f32", "ui32_to_f32", "i64_to_f32", "ui64_to_f32", "f32_to_f64", "f64_to_f32", "f32_min", "f32_max", "f32_class", "f64_add", "f64_sub", "f64_mul", "f64_div", "f64_sqrt", "f64_mulAdd", "f64_eq", "f64_lt", "f64_le", "f64_to_i32", "f64_to_ui32", "f64_to_i64", "f64_to_ui64", "i32_to_f64", "ui32_to_f64", "i64_to_f64", "ui64_to_f64", "f64_min", "f64_max", "f64_class"]

# 1-based position of s in names(), 0 if absent
def code.find(xs: List<&2, String>, +s: String, +i: U32) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{x, rest}:
      FP.sel(String.eq(x, s), i, code.find(rest, s, U32.add(i, 1)))

# number of operands
def arity(+k: U32) -> U32:
  match k:
    case 5:
      1
    case 6:
      3
    case 22:
      1
    case 27:
      1
    case 28:
      3
    case 42:
      1
    case _:
      FP.sel(Bool.or(Bool.and(U32.is_ge(k, 10), U32.is_le(k, 19)), Bool.and(U32.is_ge(k, 32), U32.is_le(k, 39))), 1, 2)

# results that FP sign-extends from 32 bits
def sext.res(+k: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(k, 10), U32.is_eq(k, 11)), Bool.or(U32.is_eq(k, 32), U32.is_eq(k, 33)))

def eval(+k: U32, +rm: U32, +a0: U32, +b0: U32, +a1: U32, +b1: U32, +a2: U32, +b2: U32) -> FP.FR:
  match k:
    case 1:
      FP.f32.add(b0, b1, rm)
    case 2:
      FP.f32.sub(b0, b1, rm)
    case 3:
      FP.f32.mul(b0, b1, rm)
    case 4:
      FP.f32.div(b0, b1, rm)
    case 5:
      FP.f32.sqrt(b0, rm)
    case 6:
      FP.f32.fma(b0, b1, b2, rm)
    case 7:
      FP.f32.eq(b0, b1)
    case 8:
      FP.f32.lt(b0, b1)
    case 9:
      FP.f32.le(b0, b1)
    case 10:
      FP.f32.to_i32(b0, rm)
    case 11:
      FP.f32.to_u32(b0, rm)
    case 12:
      FP.f32.to_i64(b0, rm)
    case 13:
      FP.f32.to_u64(b0, rm)
    case 14:
      FP.f32.of_i32(b0, rm)
    case 15:
      FP.f32.of_u32(b0, rm)
    case 16:
      FP.f32.of_i64(a0, b0, rm)
    case 17:
      FP.f32.of_u64(a0, b0, rm)
    case 18:
      FP.f32.to_f64(b0)
    case 19:
      FP.f64.to_f32(a0, b0, rm)
    case 20:
      FP.f32.min(b0, b1)
    case 21:
      FP.f32.max(b0, b1)
    case 22:
      FP.f32.class(b0)
    case 23:
      FP.f64.add(a0, b0, a1, b1, rm)
    case 24:
      FP.f64.sub(a0, b0, a1, b1, rm)
    case 25:
      FP.f64.mul(a0, b0, a1, b1, rm)
    case 26:
      FP.f64.div(a0, b0, a1, b1, rm)
    case 27:
      FP.f64.sqrt(a0, b0, rm)
    case 28:
      FP.f64.fma(a0, b0, a1, b1, a2, b2, rm)
    case 29:
      FP.f64.eq(a0, b0, a1, b1)
    case 30:
      FP.f64.lt(a0, b0, a1, b1)
    case 31:
      FP.f64.le(a0, b0, a1, b1)
    case 32:
      FP.f64.to_i32(a0, b0, rm)
    case 33:
      FP.f64.to_u32(a0, b0, rm)
    case 34:
      FP.f64.to_i64(a0, b0, rm)
    case 35:
      FP.f64.to_u64(a0, b0, rm)
    case 36:
      FP.f64.of_i32(b0, rm)
    case 37:
      FP.f64.of_u32(b0, rm)
    case 38:
      FP.f64.of_i64(a0, b0, rm)
    case 39:
      FP.f64.of_u64(a0, b0, rm)
    case 40:
      FP.f64.min(a0, b0, a1, b1)
    case 41:
      FP.f64.max(a0, b0, a1, b1)
    case 42:
      FP.f64.class(a0, b0)
    case _:
      FP.FR{0, 0, 255}

def hexval(+b: U32) -> U32:
  FP.sel(U32.is_le(b, 57), U32.sub(b, 48), FP.sel(U32.is_le(b, 70), U32.sub(b, 55), U32.sub(b, 87)))

def L.zero() -> L:
  L{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

# ends the current field: it becomes field n
def L.push(l: L) -> L:
  L{+n, +ah, +al, +a0, +b0, +a1, +b1, +a2, +b2, +a3, +b3, +a4, +b4} = l
  L{U32.add(n, 1), 0, 0, FP.sel(U32.is_eq(n, 0), ah, a0), FP.sel(U32.is_eq(n, 0), al, b0), FP.sel(U32.is_eq(n, 1), ah, a1), FP.sel(U32.is_eq(n, 1), al, b1), FP.sel(U32.is_eq(n, 2), ah, a2), FP.sel(U32.is_eq(n, 2), al, b2), FP.sel(U32.is_eq(n, 3), ah, a3), FP.sel(U32.is_eq(n, 3), al, b3), FP.sel(U32.is_eq(n, 4), ah, a4), FP.sel(U32.is_eq(n, 4), al, b4)}

def L.dig(l: L, +d: U32) -> L:
  L{n, +ah, +al, a0, b0, a1, b1, a2, b2, a3, b3, a4, b4} = l
  L{n, U32.or(U32.shln(ah, 4n), U32.shrn(al, 28n)), U32.or(U32.shln(al, 4n), d), a0, b0, a1, b1, a2, b2, a3, b3, a4, b4}

def C.add(c: C, +ok: Bool, +a0: U32, +b0: U32, +a1: U32, +b1: U32, +a2: U32, +b2: U32, +a3: U32, +b3: U32, +a4: U32, +b4: U32, r: FP.FR) -> C:
  C{+pass, +fail, +x0, +y0, +x1, +y1, +x2, +y2, +x3, +y3, +x4, +y4, +rh, +rl, +rf} = c
  FP.FR{+h, +l, +f} = r
  +first = Bool.and(Bool.not(ok), U32.is_eq(fail, 0))
  C{U32.add(pass, FP.bit(ok)), U32.add(fail, FP.bit(Bool.not(ok))), FP.sel(first, a0, x0), FP.sel(first, b0, y0), FP.sel(first, a1, x1), FP.sel(first, b1, y1), FP.sel(first, a2, x2), FP.sel(first, b2, y2), FP.sel(first, a3, x3), FP.sel(first, b3, y3), FP.sel(first, a4, x4), FP.sel(first, b4, y4), FP.sel(first, h, rh), FP.sel(first, l, rl), FP.sel(first, f, rf)}

# a complete line: evaluate and compare with the expected result and flags
def check(+k: U32, +rm: U32, l: L, c: C) -> C:
  L{n, ah, al, +a0, +b0, +a1, +b1, +a2, +b2, +a3, +b3, +a4, +b4} = l
  +r = eval(k, rm, a0, b0, a1, b1, a2, b2)
  +ar = arity(k)
  +el = FP.sel(U32.is_eq(ar, 1), b1, FP.sel(U32.is_eq(ar, 2), b2, b3))
  +eh = FP.sel(sext.res(k), FP.sel(FP.isneg(el), 4294967295, 0), FP.sel(U32.is_eq(ar, 1), a1, FP.sel(U32.is_eq(ar, 2), a2, a3)))
  +ef = FP.sel(U32.is_eq(ar, 1), b2, FP.sel(U32.is_eq(ar, 2), b3, b4))
  +ok = Bool.and(Bool.and(U32.is_eq(FP.FR.h(r), eh), U32.is_eq(FP.FR.l(r), el)), U32.is_eq(FP.FR.f(r), ef))
  C.add(c, ok, a0, b0, a1, b1, a2, b2, a3, b3, a4, b4, r)

def step.nl(+k: U32, +rm: U32, st: PS) -> PS:
  PS{l, c} = st
  PS{L.zero(), check(k, rm, L.push(l), c)}

def step.sp(st: PS) -> PS:
  PS{l, c} = st
  PS{L.push(l), c}

def step.dig(+b: U32, st: PS) -> PS:
  PS{l, c} = st
  PS{L.dig(l, hexval(b)), c}

def step(+b: U32, +k: U32, +rm: U32, st: PS) -> PS:
  match b:
    case 10:
      step.nl(k, rm, st)
    case 32:
      step.sp(st)
    case 13:
      st
    case _:
      step.dig(b, st)

def parse(bs: List<&2, U32>, +k: U32, +rm: U32, st: PS) -> PS:
  match bs:
    case Nil{}:
      st
    case Con{b, rest}:
      parse(rest, k, rm, step(b, k, rm, st))

# Output
# ------

def hexd(+d: U32) -> Char:
  Chr{U32.add(d, FP.sel(U32.is_lt(d, 10), 48, 55))}

def hex.go(n: Nat, +x: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      hex.go(p, U32.shrn(x, 4n), SCon{hexd(U32.and(x, 15)), acc})

def hex8(+x: U32) -> String:
  hex.go(8n, x, SNil{})

def hex16(+h: U32, +l: U32) -> String:
  hex8(h) ++ hex8(l)

def ssel(+c: Bool, +a: String, +b: String) -> String:
  match c:
    case True{}:
      a
    case False{}:
      b

def report(+name: String, +rm: U32, c: C) -> IO(Unit):
  C{+pass, +fail, x0, y0, x1, y1, x2, y2, x3, y3, x4, y4, rh, rl, rf} = c
  +line = "RESULT " ++ name ++ " " ++ U32.show(rm) ++ " " ++ U32.show(pass) ++ " " ++ U32.show(fail)
  +bad = "  first failure: " ++ hex16(x0, y0) ++ " " ++ hex16(x1, y1) ++ " " ++ hex16(x2, y2) ++ " " ++ hex16(x3, y3) ++ " " ++ hex16(x4, y4) ++ "\n  computed: " ++ hex16(rh, rl) ++ " flags " ++ hex8(rf)
  IO.print(line ++ ssel(U32.is_eq(fail, 0), "", "\n" ++ bad))

# Input
# -----

def is_nil(bs: List<&2, U32>) -> List<&2, U32> & Bool:
  match bs:
    case Nil{}:
      (Nil{}, True{})
    case Con{b, rest}:
      (Con{b, rest}, False{})

@unsafe
def chunk(f: File, +name: String, +k: U32, +rm: U32, st: PS, p: List<&2, U32> & Bool) -> IO(Unit):
  (bs, e) = p
  match e:
    case True{}:
      do IO<Unit>:
        File.close(f)
        fin(name, rm, st)
    case False{}:
      go(f, name, k, rm, parse(bs, k, rm, st))

@unsafe
def got(+name: String, +k: U32, +rm: U32, st: PS, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Unit):
  (f, res) = r
  match res:
    case Done{bs}:
      chunk(f, name, k, rm, st, is_nil(bs))
    case Fail{e}:
      do IO<Unit>:
        File.close(f)
        IO.die(Unit, 2, "fpu_test: read error")

@unsafe
def go(f: File, +name: String, +k: U32, +rm: U32, st: PS) -> IO(Unit):
  do IO<Unit>:
    r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 1048576)
    got(name, k, rm, st, r)

def fin(+name: String, +rm: U32, st: PS) -> IO(Unit):
  PS{l, c} = st
  report(name, rm, c)

def C.zero() -> C:
  C{0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}

@unsafe
def start(+name: String, +k: U32, +rm: U32) -> IO(Unit):
  match k:
    case 0:
      IO.die(Unit, 2, "fpu_test: unknown function " ++ name)
    case _:
      do IO<Unit>:
        f : File <- IO.try(File, File.open("/dev/stdin", "r"))
        go(f, name, k, rm, PS{L.zero(), C.zero()})

def rm.of(m: Maybe<&2, U32>) -> U32:
  match m:
    case None{}:
      0
    case Some{v}:
      v

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{+name, Con{rm, _}}}:
      start(name, code.find(names(), name, 1), rm.of(U32.read(rm)))
    case _:
      IO.print("usage: fpu_test <function> <rm>  (testfloat_gen lines on stdin)")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
