import Base
import ./hart.bend as H

# wiltee: boots a RISC-V guest on one hart. The machine is a pure function
# (H.epoch) from one epoch to the next; this file is only the IO around it:
# load the images, run an epoch, print the console, type the next command.

# The guest's physical layout (see platform/wiltee.dts).
def dtb.at() -> U32:
  133169152

def initrd.at() -> U32:
  124780544

# Instructions per epoch: about 0.1 s of guest time, which bounds input latency.
def epoch.budget() -> U32:
  1000000

# Loading
# -------

def load.byte(+a: U32, +b: U32, p: Array<U32> & U32) -> Array<U32>:
  (m, +w) = p
  +sh = U32.to_nat(U32.shln(U32.and(a, 3), 3n))
  m[U32.shrn(a, 2n)] <- U32.or(U32.and(w, U32.not(U32.shln(255, sh))), U32.shln(b, sh))
  m

# Writes bytes at byte address a (a word-aligned start takes 4 bytes a step).
def load.put(bs: List<&2, U32>, m: Array<U32>, +a: U32) -> Array<U32>:
  match bs:
    case Con{b0, Con{b1, Con{b2, Con{b3, rest}}}}:
      m[U32.shrn(a, 2n)] <- U32.or(U32.or(b0, U32.shln(b1, 8n)), U32.or(U32.shln(b2, 16n), U32.shln(b3, 24n)))
      load.put(rest, m, U32.add(a, 4))
    case Con{b, rest}:
      load.put(rest, load.byte(a, b, Array.get(U32, m, U32.shrn(a, 2n))), U32.add(a, 1))
    case Nil{}:
      m

def load.res(res: Result<&1, &1, U32 & String, List<&2, U32>>, f: File, m: Array<U32>, +a: U32, path: String) -> IO(Array<U32>):
  match res:
    case Done{bs}:
      do IO<Array<U32>>:
        File.close(f)
        return load.put(bs, m, a)
    case Fail{e}:
      do IO<Array<U32>>:
        File.close(f)
        IO.die(Array<U32>, 1, "wiltee: cannot read " ++ path)

def load.k(m: Array<U32>, +a: U32, +path: String, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Array<U32>):
  (f, res) = r
  load.res(res, f, m, a, path)

def load.go(skip: Bool, +path: String, m: Array<U32>, +a: U32) -> IO(Array<U32>):
  match skip:
    case True{}:
      IO.pure(Array<U32>, m)
    case False{}:
      do IO<Array<U32>>:
        f : File <- IO.try(File, File.open(path, "r"))
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 33554432)
        load.k(m, a, path, r)

# Loads a file at physical address a; "-" loads nothing.
def load.file(+path: String, m: Array<U32>, +a: U32) -> IO(Array<U32>):
  load.go(String.eq(path, "-"), path, m, a)

# Console
# -------

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

# The last four console bytes, to spot a prompt: "login: " or a shell's "# ".
def tail.fold(bs: List<&2, U32>, +tl: U32) -> U32:
  match bs:
    case Nil{}:
      tl
    case Con{b, rest}:
      tail.fold(rest, U32.or(U32.shln(tl, 8n), b))

def at.prompt(+tl: U32) -> Bool:
  Bool.or(U32.is_eq(U32.and(tl, 65535), 8992), U32.is_eq(tl, 1768831520))

# A byte from the user's terminal, without waiting: 0..255; 4294967295 none
# pending; 4294967294 end of input; 4294967293 Ctrl-A x (quit).
def Tty.getc() -> IO(U32):
  import "./tty.c"
  import "./tty.js"

type Inp is Data:
  Inp{bytes: List<&2, U32>, st: U32}

# The host loop
# -------------
# Each turn runs one epoch (a pure call), prints what the guest wrote, then
# gives the guest its input: the user's keystrokes, or at a prompt the next
# scripted line. Unbounded, so @unsafe; the machine itself (hart.bend) is
# total. Interactive runs pace guest time (one tick per instruction, 10 MHz)
# to the wall clock, so an idle guest sleeps instead of racing ahead.

def host.bye(why: String, r: H.Hart & (U32 & U32)) -> IO(Unit):
  (h, c) = r
  (hi, lo) = c
  IO.print("\n[wiltee] " ++ why ++ " after " ++ U32.show(lo) ++ " + " ++ U32.show(hi) ++ "*2^32 instructions")

def host.why(ex: U32) -> String:
  match ex:
    case 1:
      "powered off"
    case 2:
      "asleep with no wake source"
    case _:
      "reboot requested"

@unsafe
def tty.more(c: U32, k: Nat, acc: List<&2, U32>) -> IO(Inp):
  match c:
    case 4294967295:
      IO.pure(Inp, Inp{List.reverse(&2, U32, acc), 0})
    case 4294967294:
      IO.pure(Inp, Inp{List.reverse(&2, U32, acc), 1})
    case 4294967293:
      IO.pure(Inp, Inp{List.reverse(&2, U32, acc), 2})
    case _:
      tty.read(k, c <> acc)

# Up to k pending keystrokes.
@unsafe
def tty.read(k: Nat, acc: List<&2, U32>) -> IO(Inp):
  match k:
    case 0n:
      IO.pure(Inp, Inp{List.reverse(&2, U32, acc), 0})
    case 1n+p:
      do IO<Inp>:
        c : U32 <- Tty.getc()
        tty.more(c, p, acc)

def guest.ms(+hi: U32, +lo: U32) -> Nat:
  Nat.div(Nat.add(Nat.add(Nat.mul(U32.to_nat(hi), 4294967295n), U32.to_nat(hi)), U32.to_nat(lo)), 10000n)

# Milliseconds to sleep so guest time does not pass wall time (at most 50).
def pace.ms(+vt: Nat, +wall: Nat) -> U32:
  U32.min(U32.from_nat(Nat.sub(vt, wall)), 50)

@unsafe
def host.input(script: List<String>, +k: Nat, +eof: Bool, +tl: U32, +t0: Nat, h: H.Hart, i: Inp) -> IO(Unit):
  Inp{bs, +st} = i
  match st:
    case 2:
      host.bye("quit", H.Hart.count(h))
    case _:
      host.loop(k, H.Hart.feed(bs, h), script, Bool.or(eof, U32.is_eq(st, 1)), tl, t0)

@unsafe
def host.pace(+k: Nat, +eof: Bool, +tl: U32, +t0: Nat, r: H.Hart & (U32 & U32)) -> IO(Unit):
  (h, c) = r
  (hi, lo) = c
  do IO<Unit>:
    now : Nat <- IO.now()
    IO.sleep(pace.ms(guest.ms(hi, lo), Nat.sub(now, t0)))
    i : Inp <- host.keys(eof)
    host.input(Nil{}, k, eof, tl, t0, h, i)

@unsafe
def host.keys(+eof: Bool) -> IO(Inp):
  match eof:
    case True{}:
      IO.pure(Inp, Inp{Nil{}, 1})
    case False{}:
      tty.read(64n, Nil{})

@unsafe
def host.feed(+at: Bool, script: List<String>, +k: Nat, +eof: Bool, +tl: U32, +t0: Nat, h: H.Hart) -> IO(Unit):
  match at script:
    case True{} Con{line, rest}:
      host.loop(k, H.Hart.feed(str.bytes(line ++ "\n"), h), rest, eof, 0, t0)
    case _ Con{line, rest}:
      host.loop(k, h, Con{line, rest}, eof, tl, t0)
    case _ Nil{}:
      host.pace(k, eof, tl, t0, H.Hart.count(h))

@unsafe
def host.next(+k: Nat, script: List<String>, +eof: Bool, +tl: U32, +t0: Nat, r: H.Hart & U32) -> IO(Unit):
  (h, +ex) = r
  match ex:
    case 0:
      host.feed(at.prompt(tl), script, k, eof, tl, t0, h)
    case _:
      host.bye(host.why(ex), H.Hart.count(h))

def err.line(s: String) -> IO(Unit):
  match s:
    case SNil{}:
      IO.pure(Unit, Unit{})
    case SCon{c, rest}:
      IO.print_err(SCon{c, rest})

@unsafe
def host.out2(+k: Nat, script: List<String>, +eof: Bool, +tl: U32, +t0: Nat, +bs: List<&2, U32>, r: H.Hart & String) -> IO(Unit):
  (h, line) = r
  do IO<Unit>:
    IO.write(bytes.str(bs))
    err.line(line)
    host.next(k, script, eof, tail.fold(bs, tl), t0, H.Hart.exit(h))

@unsafe
def host.out(+k: Nat, script: List<String>, +eof: Bool, +tl: U32, +t0: Nat, r: H.Hart & List<&2, U32>) -> IO(Unit):
  (h, +bs) = r
  host.out2(k, script, eof, tl, t0, bs, H.Hart.trace(h))

# script: lines still to type at prompts; once it is empty the user's
# terminal drives the guest. eof: stdin has ended.
@unsafe
def host.loop(+k: Nat, h: H.Hart, script: List<String>, +eof: Bool, +tl: U32, +t0: Nat) -> IO(Unit):
  match k:
    case 0n:
      host.bye("epoch limit reached", H.Hart.count(h))
    case 1n+p:
      host.out(p, script, eof, tl, t0, H.Hart.drain(H.epoch(1000000n, H.Hart.arm(epoch.budget(), h))))

# Entry
# -----

def trace.on(r: Result<&1, &1, U32 & String, String>) -> U32:
  match r:
    case Done{v}:
      H.bit(Bool.not(String.eq(v, "")))
    case Fail{e}:
      0

@unsafe
def boot(kernel: String, dtb: String, initrd: String, script: List<String>) -> IO(Unit):
  do IO<Unit>:
    m0 : Array<U32> = [0 : U32*33554432n]
    m1 : Array<U32> <- load.file(kernel, m0, 0)
    m2 : Array<U32> <- load.file(dtb, m1, dtb.at())
    m3 : Array<U32> <- load.file(initrd, m2, initrd.at())
    tr : Result<&1, &1, U32 & String, String> <- IO.get_env("WILTEE_TRACE")
    t0 : Nat <- IO.now()
    host.loop(4294967295n, H.Hart.set_trace(trace.on(tr), H.Hart.new(m3, 0, dtb.at(), 0)), script, False{}, 0, t0)

@unsafe
def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{_, Con{kernel, Con{dtb, Con{initrd, script}}}}:
      boot(kernel, dtb, initrd, script)
    case _:
      IO.print("usage: wiltee <kernel|-> <dtb|-> <initrd|-> [line ...]\n  lines are typed at prompts; then the terminal drives the guest (Ctrl-A x quits)")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
