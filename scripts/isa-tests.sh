#!/usr/bin/env bash
# Builds the official riscv-tests (rv32ui, rv32um, rv32ua) against wiltee's
# S-mode test environment (tests/isa/riscv_test.h) and runs each on the
# emulator. Needs clang and ld.lld (any recent LLVM) and build/wiltee.
set -euo pipefail
cd "$(dirname "$0")/.."
REV=3df703cd52d5f0d8224e3c50bf03c6cb70efff98
SRC=build/riscv-tests
OUT=build/isa
CC=${CC:-$(command -v clang-19 || command -v clang)}
LD=${LD:-$(command -v ld.lld-19 || command -v ld.lld)}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy-19 || command -v llvm-objcopy)}
EMU=${EMU:-build/wiltee}

if [ ! -d "$SRC" ]; then
  git clone -q https://github.com/riscv-software-src/riscv-tests "$SRC"
  git -C "$SRC" checkout -q "$REV"
fi
mkdir -p "$OUT"

# ma_data needs misaligned accesses, which wiltee traps (as semu does) and
# this environment has no handler for.
tests=()
for suite in rv32ui rv32um rv32ua; do
  for t in "$SRC"/isa/$suite/*.S; do
    name=$(basename "$t" .S)
    [ "$suite/$name" = rv32ui/ma_data ] && continue
    tests+=("$suite/$name")
  done
done

pass=0; fail=0; failed=()
for t in "${tests[@]}"; do
  bin=$OUT/${t//\//-}.bin
  $CC --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib -c \
    -I tests/isa -I "$SRC/isa/macros/scalar" "$SRC/isa/$t.S" -o "$bin.o"
  $LD -Ttext=0 -o "$bin.elf" "$bin.o"
  $OBJCOPY -O binary "$bin.elf" "$bin"
  if out=$(timeout 60 "$EMU" "$bin" - - 2>&1) && grep -q '^PASS' <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$t: $(head -1 <<<"$out")")
  fi
done
echo "isa tests: $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "  FAIL $f"; done
[ "$fail" -eq 0 ]
