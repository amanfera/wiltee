import Base

# RVC (RV64GC "C" extension) expander: 16-bit halfword -> 32-bit instruction.
# Reserved and RV32-only encodings return 0; hints expand to harmless base
# instructions (writes to x0), never 0.

# Field helpers
# -------------

# bits [n .. n+width) of x selected by mask m, moved to bit position t
def C.mv(+x: U32, n: Nat, +m: U32, t: Nat) -> U32:
  U32.shln(U32.and(U32.shrn(x, n), m), t)

def C.f(+x: U32, n: Nat, +m: U32) -> U32:
  U32.and(U32.shrn(x, n), m)

# 0 if x == 0, else v
def C.nz(+x: U32, +v: U32) -> U32:
  match x:
    case 0:
      0
    case _:
      v

def C.sx(+v: U32, +m: U32) -> U32:
  U32.sub(U32.xor(v, m), m)

# Encoders (k holds the pre-merged funct3 and opcode)
# -----------------------------------------------------

def C.encI(+imm: U32, +rs1: U32, +rd: U32, +k: U32) -> U32:
  U32.or(
    U32.or(U32.shln(U32.and(imm, 4095), 20n), U32.shln(rs1, 15n)),
    U32.or(U32.shln(rd, 7n), k))

def C.encR(+f7: U32, +rs2: U32, +rs1: U32, +rd: U32, +k: U32) -> U32:
  U32.or(
    U32.or(U32.shln(f7, 25n), U32.shln(rs2, 20n)),
    U32.or(U32.or(U32.shln(rs1, 15n), U32.shln(rd, 7n)), k))

def C.encS(+imm: U32, +rs2: U32, +rs1: U32, +k: U32) -> U32:
  U32.or(
    U32.or(C.mv(imm, 5n, 127, 25n), U32.shln(rs2, 20n)),
    U32.or(U32.or(U32.shln(rs1, 15n), C.mv(imm, 0n, 31, 7n)), k))

def C.encB(+imm: U32, +rs1: U32, +k: U32) -> U32:
  U32.or(
    U32.or(C.mv(imm, 12n, 1, 31n), C.mv(imm, 5n, 63, 25n)),
    U32.or(U32.or(U32.shln(rs1, 15n), C.mv(imm, 1n, 15, 8n)),
      U32.or(C.mv(imm, 11n, 1, 7n), k)))

def C.encJ(+imm: U32) -> U32:
  U32.or(
    U32.or(C.mv(imm, 20n, 1, 31n), C.mv(imm, 1n, 1023, 21n)),
    U32.or(C.mv(imm, 11n, 1, 20n), U32.or(C.mv(imm, 12n, 255, 12n), 111)))

# Registers
# ---------

def C.rd(+h: U32) -> U32:
  C.f(h, 7n, 31)

def C.rs2(+h: U32) -> U32:
  C.f(h, 2n, 31)

# rs1' / rd' (bits 9:7) and rs2' / rd' (bits 4:2), offset by 8
def C.rpa(+h: U32) -> U32:
  U32.add(C.f(h, 7n, 7), 8)

def C.rpb(+h: U32) -> U32:
  U32.add(C.f(h, 2n, 7), 8)

# Immediates (as laid out in the spec, unsigned unless sign-extended)
# -------------------------------------------------------------------

def C.immD(+h: U32) -> U32:
  U32.or(C.mv(h, 10n, 7, 3n), C.mv(h, 5n, 3, 6n))

def C.immW(+h: U32) -> U32:
  U32.or(U32.or(C.mv(h, 10n, 7, 3n), C.mv(h, 6n, 1, 2n)), C.mv(h, 5n, 1, 6n))

def C.imm6(+h: U32) -> U32:
  U32.or(C.mv(h, 12n, 1, 5n), C.mv(h, 2n, 31, 0n))

def C.simm6(+h: U32) -> U32:
  C.sx(C.imm6(h), 32)

def C.immJ(+h: U32) -> U32:
  U32.and(
    C.sx(
      U32.or(
        U32.or(U32.or(C.mv(h, 12n, 1, 11n), C.mv(h, 11n, 1, 4n)),
          U32.or(C.mv(h, 9n, 3, 8n), C.mv(h, 8n, 1, 10n))),
        U32.or(U32.or(C.mv(h, 7n, 1, 6n), C.mv(h, 6n, 1, 7n)),
          U32.or(C.mv(h, 3n, 7, 1n), C.mv(h, 2n, 1, 5n)))),
      2048),
    2097151)

def C.immB(+h: U32) -> U32:
  C.sx(
    U32.or(
      U32.or(C.mv(h, 12n, 1, 8n), C.mv(h, 10n, 3, 3n)),
      U32.or(U32.or(C.mv(h, 5n, 3, 6n), C.mv(h, 3n, 3, 1n)), C.mv(h, 2n, 1, 5n))),
    256)

# Quadrant 0
# ----------

def C.immSP4(+h: U32) -> U32:
  U32.or(
    U32.or(C.mv(h, 7n, 15, 6n), C.mv(h, 11n, 3, 4n)),
    U32.or(C.mv(h, 5n, 1, 3n), C.mv(h, 6n, 1, 2n)))

def C.addi4spn.e(+h: U32, +imm: U32) -> U32:
  C.nz(imm, C.encI(imm, 2, C.rpb(h), 19))

def C.addi4spn(+h: U32) -> U32:
  C.addi4spn.e(h, C.immSP4(h))

# loads: rd' = bits 4:2, rs1' = bits 9:7; k = funct3|opcode
def C.ldD(+h: U32, +k: U32) -> U32:
  C.encI(C.immD(h), C.rpa(h), C.rpb(h), k)

def C.ldW(+h: U32) -> U32:
  C.encI(C.immW(h), C.rpa(h), C.rpb(h), 8195)

# stores: rs2' = bits 4:2
def C.stD(+h: U32, +k: U32) -> U32:
  C.encS(C.immD(h), C.rpb(h), C.rpa(h), k)

def C.stW(+h: U32) -> U32:
  C.encS(C.immW(h), C.rpb(h), C.rpa(h), 8227)

# Quadrant 1
# ----------

def C.addi(+h: U32) -> U32:
  C.encI(C.simm6(h), C.rd(h), C.rd(h), 19)

def C.addiw(+h: U32) -> U32:
  C.nz(C.rd(h), C.encI(C.simm6(h), C.rd(h), C.rd(h), 27))

def C.li(+h: U32) -> U32:
  C.encI(C.simm6(h), 0, C.rd(h), 19)

def C.immSP16(+h: U32) -> U32:
  C.sx(
    U32.or(
      U32.or(C.mv(h, 12n, 1, 9n), C.mv(h, 6n, 1, 4n)),
      U32.or(U32.or(C.mv(h, 5n, 1, 6n), C.mv(h, 3n, 3, 7n)), C.mv(h, 2n, 1, 5n))),
    512)

def C.addi16sp.e(+imm: U32) -> U32:
  C.nz(imm, C.encI(imm, 2, 2, 19))

def C.lui.e(+h: U32, +imm: U32) -> U32:
  C.nz(imm,
    U32.or(U32.shln(U32.and(imm, 1048575), 12n), U32.or(U32.shln(C.rd(h), 7n), 55)))

def C.q1_3.e(+h: U32, +rd: U32) -> U32:
  match rd:
    case 2:
      C.addi16sp.e(C.immSP16(h))
    case _:
      C.lui.e(h, C.simm6(h))

def C.q1_3(+h: U32) -> U32:
  C.q1_3.e(h, C.rd(h))

# shifts and andi on rd' (bits 9:7); srai sets bit 10 of the immediate
def C.srli(+h: U32) -> U32:
  C.encI(C.imm6(h), C.rpa(h), C.rpa(h), 20499)

def C.srai(+h: U32) -> U32:
  C.encI(U32.or(C.imm6(h), 1024), C.rpa(h), C.rpa(h), 20499)

def C.andi(+h: U32) -> U32:
  C.encI(C.simm6(h), C.rpa(h), C.rpa(h), 28691)

def C.alu(+h: U32, +f7: U32, +k: U32) -> U32:
  C.encR(f7, C.rpb(h), C.rpa(h), C.rpa(h), k)

# key = bit 12 | bits 6:5
def C.q1reg.e(+h: U32, +key: U32) -> U32:
  match key:
    case 0:
      C.alu(h, 32, 51)
    case 1:
      C.alu(h, 0, 16435)
    case 2:
      C.alu(h, 0, 24627)
    case 3:
      C.alu(h, 0, 28723)
    case 4:
      C.alu(h, 32, 59)
    case 5:
      C.alu(h, 0, 59)
    case _:
      0

def C.q1reg(+h: U32) -> U32:
  C.q1reg.e(h, U32.or(C.mv(h, 12n, 1, 2n), C.mv(h, 5n, 3, 0n)))

def C.q1alu.e(+h: U32, +key: U32) -> U32:
  match key:
    case 0:
      C.srli(h)
    case 1:
      C.srai(h)
    case 2:
      C.andi(h)
    case _:
      C.q1reg(h)

def C.q1alu(+h: U32) -> U32:
  C.q1alu.e(h, C.f(h, 10n, 3))

def C.j(+h: U32) -> U32:
  C.encJ(C.immJ(h))

def C.br(+h: U32, +k: U32) -> U32:
  C.encB(C.immB(h), C.rpa(h), k)

# Quadrant 2
# ----------

def C.slli(+h: U32) -> U32:
  C.encI(C.imm6(h), C.rd(h), C.rd(h), 4115)

def C.immLDSP(+h: U32) -> U32:
  U32.or(C.mv(h, 12n, 1, 5n), U32.or(C.mv(h, 5n, 3, 3n), C.mv(h, 2n, 7, 6n)))

def C.immLWSP(+h: U32) -> U32:
  U32.or(C.mv(h, 12n, 1, 5n), U32.or(C.mv(h, 4n, 7, 2n), C.mv(h, 2n, 3, 6n)))

def C.immSWSP(+h: U32) -> U32:
  U32.or(C.mv(h, 9n, 15, 2n), C.mv(h, 7n, 3, 6n))

def C.immSDSP(+h: U32) -> U32:
  U32.or(C.mv(h, 10n, 7, 3n), C.mv(h, 7n, 7, 6n))

def C.fldsp(+h: U32) -> U32:
  C.encI(C.immLDSP(h), 2, C.rd(h), 12295)

def C.lwsp(+h: U32) -> U32:
  C.nz(C.rd(h), C.encI(C.immLWSP(h), 2, C.rd(h), 8195))

def C.ldsp(+h: U32) -> U32:
  C.nz(C.rd(h), C.encI(C.immLDSP(h), 2, C.rd(h), 12291))

def C.fsdsp(+h: U32) -> U32:
  C.encS(C.immSDSP(h), C.rs2(h), 2, 12327)

def C.swsp(+h: U32) -> U32:
  C.encS(C.immSWSP(h), C.rs2(h), 2, 8227)

def C.sdsp(+h: U32) -> U32:
  C.encS(C.immSDSP(h), C.rs2(h), 2, 12323)

# bit 12 = 0, rs2 = 0: C.JR (rs1 = 0 reserved); else C.MV
def C.q2lo.e(+h: U32, +rs2: U32) -> U32:
  match rs2:
    case 0:
      C.nz(C.rd(h), C.encI(0, C.rd(h), 0, 103))
    case _:
      C.encR(0, rs2, 0, C.rd(h), 51)

def C.ebj.e(+h: U32, +rs1: U32) -> U32:
  match rs1:
    case 0:
      1048691
    case _:
      C.encI(0, rs1, 1, 103)

# bit 12 = 1, rs2 = 0: C.EBREAK / C.JALR; else C.ADD
def C.q2hi.e(+h: U32, +rs2: U32) -> U32:
  match rs2:
    case 0:
      C.ebj.e(h, C.rd(h))
    case _:
      C.encR(0, rs2, C.rd(h), C.rd(h), 51)

def C.q2_4.e(+h: U32, +b: U32) -> U32:
  match b:
    case 0:
      C.q2lo.e(h, C.rs2(h))
    case _:
      C.q2hi.e(h, C.rs2(h))

def C.q2_4(+h: U32) -> U32:
  C.q2_4.e(h, C.f(h, 12n, 1))

# Dispatch on key = quadrant * 8 + funct3
# ---------------------------------------

def C.dispatch(+h: U32, +key: U32) -> U32:
  match key:
    case 0:
      C.addi4spn(h)
    case 1:
      C.ldD(h, 12295)
    case 2:
      C.ldW(h)
    case 3:
      C.ldD(h, 12291)
    case 5:
      C.stD(h, 12327)
    case 6:
      C.stW(h)
    case 7:
      C.stD(h, 12323)
    case 8:
      C.addi(h)
    case 9:
      C.addiw(h)
    case 10:
      C.li(h)
    case 11:
      C.q1_3(h)
    case 12:
      C.q1alu(h)
    case 13:
      C.j(h)
    case 14:
      C.br(h, 99)
    case 15:
      C.br(h, 4195)
    case 16:
      C.slli(h)
    case 17:
      C.fldsp(h)
    case 18:
      C.lwsp(h)
    case 19:
      C.ldsp(h)
    case 20:
      C.q2_4(h)
    case 21:
      C.fsdsp(h)
    case 22:
      C.swsp(h)
    case 23:
      C.sdsp(h)
    case _:
      0

# Expand a 16-bit RVC halfword to its 32-bit encoding; 0 if reserved/illegal.
def C.expand(+h: U32) -> U32:
  C.dispatch(h,
    U32.add(U32.shln(U32.and(h, 3), 3n), U32.and(U32.shrn(h, 13n), 7)))
