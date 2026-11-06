#!/usr/bin/env python3
"""Compares C.expand (src/rvc.bend) with LLVM for every RV64C halfword.

usage: compare.py LLVM_MC DRIVER_OUTPUT WORKDIR

DRIVER_OUTPUT is what tests/rvc/expand.bend prints: "<halfword> <expansion>".

LLVM reference (riscv64, +c,+f,+d):
  1. `llvm-mc --disassemble` prints a valid compressed instruction as the base
     instruction it expands to (its printer uncompresses when aliases are on),
     leaves HINT encodings compressed (`c.nop 3`), and rejects the rest.
  2. The base instructions are assembled again with -c: the reference bits.

What C.expand(h) must return:
  valid     the reference bits, exactly. C.MV is the one exception: LLVM prints
            it as `mv rd, rs2`, which assembles to `addi rd, rs2, 0`, while the
            spec expands it to `add rd, x0, rs2`; the spec form is expected and
            LLVM's own compressor is asked to map it back to h.
  hint      a base instruction that writes only x0 (LUI, an immediate or a
            register operation) and so has no architectural effect, never 0.
            The spec also lets a HINT rewrite rd with its own value (C.ADDI t0,
            0); those 78 code points are held to the stricter x0 rule too.
  reserved  0.
spec_class() holds the spec's table, independent of LLVM, and is cross-checked
against what LLVM accepts. LLVM 19 accepts two kinds of reserved code points:
the all-zero halfword (`unimp`) and C.LUI with nzimm = 0 (`lui rd, 0`).
"""
import re
import subprocess
import sys


def die(msg):
    print('rvc: ' + msg, file=sys.stderr)
    sys.exit(2)


def spec_class(h):
    """RV64C: 'valid', 'hint' or 'reserved' (RISC-V unprivileged ISA, ch. C)."""
    q, f3, b12 = h & 3, h >> 13, h >> 12 & 1
    rd, rs2 = h >> 7 & 31, h >> 2 & 31
    imm6 = b12 << 5 | rs2  # CI immediate, or the shift amount
    if q == 0:
        if f3 == 0:  # C.ADDI4SPN, nzuimm = 0 (the all-zero halfword included)
            return 'reserved' if h >> 5 & 255 == 0 else 'valid'
        return 'reserved' if f3 == 4 else 'valid'
    if q == 1:
        if f3 == 0:  # C.NOP / C.ADDI
            return 'valid' if (rd == 0) == (imm6 == 0) else 'hint'
        if f3 == 1:  # C.ADDIW (C.JAL on RV32)
            return 'reserved' if rd == 0 else 'valid'
        if f3 == 2:  # C.LI
            return 'hint' if rd == 0 else 'valid'
        if f3 == 3:  # C.LUI / C.ADDI16SP
            if imm6 == 0:
                return 'reserved'
            return 'hint' if rd == 0 else 'valid'
        if f3 == 4:
            op = h >> 10 & 3
            if op < 2:  # C.SRLI / C.SRAI
                return 'hint' if imm6 == 0 else 'valid'
            if op == 2:  # C.ANDI
                return 'valid'
            # C.SUB C.XOR C.OR C.AND C.SUBW C.ADDW
            return 'reserved' if b12 and h >> 5 & 3 >= 2 else 'valid'
        return 'valid'  # C.J C.BEQZ C.BNEZ
    if f3 == 0:  # C.SLLI
        return 'hint' if rd == 0 or imm6 == 0 else 'valid'
    if f3 in (2, 3):  # C.LWSP / C.LDSP
        return 'reserved' if rd == 0 else 'valid'
    if f3 != 4:  # C.FLDSP C.FSDSP C.SWSP C.SDSP
        return 'valid'
    if rs2:  # C.MV / C.ADD
        return 'hint' if rd == 0 else 'valid'
    if b12 == 0:  # C.JR
        return 'reserved' if rd == 0 else 'valid'
    return 'valid'  # C.EBREAK / C.JALR


def llvm_lenient(h):
    """Reserved encodings that LLVM 19 decodes: `unimp`, `lui rd, 0`."""
    c_lui_zero = h >> 13 == 3 and h & 3 == 1 and h & 0x107c == 0 and h >> 7 & 31 != 2
    return h == 0 or c_lui_zero


def harmless(e):
    """A RV64I computational instruction (LUI, OP-IMM, OP) that writes only x0."""
    op, rd, f3, imm, f7 = e & 127, e >> 7 & 31, e >> 12 & 7, e >> 20, e >> 25
    if rd:
        return False
    if op == 0x37:  # LUI
        return True
    if op == 0x33:  # ADD SUB SLL SLT SLTU XOR SRL SRA OR AND
        return f7 == 0 or (f7 == 32 and f3 in (0, 5))
    if op == 0x13:  # SLLI, SRLI and SRAI take a 6-bit shift amount
        return {1: imm >> 6 == 0, 5: imm >> 6 in (0, 16)}.get(f3, True)
    return False


def run(mc, args, text):
    r = subprocess.run([mc, '-triple=riscv64', *args], input=text,
                       capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def assemble(mc, mattr, lines):
    """Encodings (little-endian ints) of one instruction per line."""
    rc, out, err = run(mc, [f'-mattr={mattr}', '-show-encoding'],
                       '\n'.join(lines) + '\n')
    if rc or err:
        die('llvm-mc failed to assemble the expansions:\n' + err[:2000])
    encs = [sum(int(b, 16) << 8 * i for i, b in enumerate(m[1].split(',')))
            for m in map(re.compile(r'# encoding: \[([^\]]*)\]').search,
                         out.splitlines()) if m]
    if len(encs) != len(lines):
        die(f'assembled {len(encs)} instructions from {len(lines)} lines')
    return encs


def disassemble(mc, halfwords):
    """{halfword: base-instruction or compressed-hint text}, plus the halfwords
    LLVM rejects (one warning each, at the start of its own input line)."""
    text = ''.join('0x%02x 0x%02x\n' % (h & 255, h >> 8) for h in halfwords)
    rc, out, err = run(mc, ['--disassemble', '-show-encoding',
                            '-mattr=+c,+f,+d'], text)
    if rc:
        die('llvm-mc --disassemble failed:\n' + err[:2000])
    seen = {}
    for ln in out.splitlines():
        m = re.fullmatch(r'\t(.*?)\s*# encoding: \[0x(..),0x(..)\]', ln)
        if m:
            seen[int(m[3], 16) << 8 | int(m[2], 16)] = m[1]
        elif ln != '\t.text':
            die('unexpected disassembler output: ' + ln)
    bad = set()
    for m in re.finditer(r'^<stdin>:(\d+):(\d+): warning: invalid instruction'
                         r' encoding$', err, re.M):
        if m[2] != '1':
            die('rejected halfword is not at the start of its line: ' + m[0])
        bad.add(halfwords[int(m[1]) - 1])
    if (set(seen) & bad) or (set(seen) | bad) != set(halfwords):
        die('disassembly does not account for every halfword exactly once')
    return seen, bad


def show(mc, e):
    """What llvm-mc makes of the 32-bit word e, for the mismatch listing."""
    _, out, _ = run(mc, ['--disassemble', '-mattr=-c,+f,+d'],
                    ' '.join('0x%02x' % (e >> 8 * i & 255) for i in range(4)))
    return ' '.join(out.replace('.text', '').split()) or 'invalid'


def main():
    mc, driver_out, work = sys.argv[1:4]
    halfwords = [h for h in range(1 << 16) if h & 3 != 3]
    got = {}
    for ln in open(driver_out):
        m = re.fullmatch(r'([0-9a-f]{4}) ([0-9a-f]{8})\n', ln)
        if not m:
            die(f'bad driver output line: {ln!r}')
        got[int(m[1], 16)] = int(m[2], 16)
    if sorted(got) != halfwords:
        die(f'driver printed {len(got)} halfwords, expected {len(halfwords)}')

    seen, rejected = disassemble(mc, halfwords)
    spec = {h: spec_class(h) for h in halfwords}
    n = {k: sum(v == k for v in spec.values()) for k in ('valid', 'hint', 'reserved')}
    # RVC HINT table, RV64: C.NOP 63, C.ADDI 31, C.LI 64, C.LUI 63, C.MV 31,
    # C.ADD 31, C.SLLI 95, C.SRLI 8, C.SRAI 8
    if n['hint'] != 63 + 31 + 64 + 63 + 31 + 31 + 95 + 8 + 8:
        die(f"spec_class finds {n['hint']} HINT code points, the spec lists 394")

    problems = []  # (halfword, what)
    # Spec versus LLVM.
    lenient = 0
    for h in halfwords:
        t = seen.get(h)
        want = {'valid': 'a base instruction', 'hint': 'a compressed HINT',
                'reserved': 'a rejection'}[spec[h]]
        have = ('a rejection' if t is None else 'a compressed HINT'
                if t.startswith('c.') else 'a base instruction')
        if spec[h] == 'reserved' and t is not None and llvm_lenient(h):
            lenient += 1
        elif have != want:
            problems.append((h, f'spec says {spec[h]}, LLVM gives {have}: {t}'))

    # The reference bits for valid code points; C.MV as the spec expands it.
    text, mvs = {}, []
    for h in halfwords:
        if spec[h] == 'valid' and h in seen:
            text[h] = seen[h]
            m = re.fullmatch(r'mv\s+(\w+),\s*(\w+)', seen[h])
            if m and h & 0xf003 == 0x8002:
                text[h] = f'add {m[1]}, zero, {m[2]}'
                mvs.append(h)
    hs = list(text)
    ref = dict(zip(hs, assemble(mc, '+f,+d,-c', [text[h] for h in hs])))
    back = assemble(mc, '+c,+f,+d', [text[h] for h in mvs])
    for h, b in zip(mvs, back):
        if b != h:
            problems.append((h, f'LLVM compresses `{text[h]}` to {b:04x}, not back to {h:04x}'))

    # Expansions.
    bad = []
    for h in halfwords:
        e = got[h]
        if spec[h] == 'reserved':
            ok = e == 0
        elif spec[h] == 'hint':
            ok = harmless(e)
        else:
            ok = e == ref[h]
        if not ok:
            bad.append(h)

    with open(work + '/reference.txt', 'w') as f:
        for h in halfwords:
            r = f'{ref[h]:08x}' if h in ref else '-'
            f.write(f'{h:04x} {spec[h]:8s} {r:8s} {seen.get(h, "(rejected)")}\n')

    for h, what in problems[:20]:
        print(f'{h:04x}: {what}')
    for h in bad[:20]:
        r = {'hint': 'a write to x0', 'reserved': '00000000'}.get(spec[h]) or f'{ref[h]:08x}'
        print(f'{h:04x}: {seen.get(h, "(rejected)")}\n'
              f'      expected {r}, got {got[h]:08x} = {show(mc, got[h])}')
    if len(problems) > 20 or len(bad) > 20:
        print('...')

    vers = subprocess.run([mc, '--version'], capture_output=True, text=True).stdout
    print(f'llvm-mc: {vers.splitlines()[0]}')
    print(f"  valid {n['valid']}: LLVM's expansion, bit for bit")
    print(f"  hint {n['hint']}: a write to x0")
    print(f"  reserved {n['reserved']}: 0 ({lenient} of them decoded by LLVM)")
    total = len(bad) + len(problems)
    print(f'rvc: {len(halfwords)} halfwords checked, {total} mismatches')
    sys.exit(1 if total else 0)


main()
