#!/usr/bin/env bash
# Builds the official riscv-tests against wiltee's S-mode test environment
# (tests/isa/riscv_test.h) and runs each on the emulator.
#   scripts/isa-tests.sh             rv32ui rv32um rv32ua on build/wiltee
#   XLEN=64 scripts/isa-tests.sh     rv64ui rv64um rv64ua rv64uc on build/wiltee64
#   XLEN=64 scripts/isa-tests.sh rv64uf rv64ud    (suites as arguments)
# Needs clang and ld.lld (any recent LLVM).
set -euo pipefail
cd "$(dirname "$0")/.."
REV=3df703cd52d5f0d8224e3c50bf03c6cb70efff98
SRC=build/riscv-tests
XLEN=${XLEN:-32}
CC=${CC:-$(command -v clang-19 || command -v clang)}
LD=${LD:-$(command -v ld.lld-19 || command -v ld.lld)}
OBJCOPY=${OBJCOPY:-$(command -v llvm-objcopy-19 || command -v llvm-objcopy)}
if [ "$XLEN" = 64 ]; then
  EMU=${EMU:-build/wiltee64}; OUT=build/isa64; ABI=lp64; DEFAULT="rv64ui rv64um rv64ua rv64uc"
else
  EMU=${EMU:-build/wiltee}; OUT=build/isa; ABI=ilp32; DEFAULT="rv32ui rv32um rv32ua"
fi
read -ra suites <<< "${*:-$DEFAULT}"

if [ ! -d "$SRC" ]; then
  git clone -q https://github.com/riscv-software-src/riscv-tests "$SRC"
  git -C "$SRC" checkout -q "$REV"
fi
mkdir -p "$OUT"

# ma_data needs misaligned accesses, which wiltee traps (as semu does) and
# this environment has no handler for.
tests=()
for suite in "${suites[@]}"; do
  for t in "$SRC"/isa/$suite/*.S; do
    name=$(basename "$t" .S)
    [ "$name" = ma_data ] && continue
    tests+=("$suite/$name")
  done
done

# Only the C suite is assembled with compression, so the others test the
# 32-bit encodings; F and D suites need those extensions.
march() {
  case $1 in
    *uc/*) echo "rv${XLEN}imac" ;;
    *uf/*) echo "rv${XLEN}imaf" ;;
    *ud/*) echo "rv${XLEN}imafd" ;;
    *) echo "rv${XLEN}ima" ;;
  esac
}

pass=0; fail=0; failed=()
for t in "${tests[@]}"; do
  bin=$OUT/${t//\//-}.bin
  $CC --target=riscv$XLEN -march="$(march "$t")" -mabi=$ABI -nostdlib -c \
    -I tests/isa -I "$SRC/isa/macros/scalar" "$SRC/isa/$t.S" -o "$bin.o"
  $LD -Ttext=0 -o "$bin.elf" "$bin.o"
  $OBJCOPY -O binary "$bin.elf" "$bin"
  if out=$(timeout 60 "$EMU" "$bin" - - 2>&1) && grep -q '^PASS' <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); failed+=("$t: $(head -1 <<<"$out")")
  fi
done
echo "isa tests ($XLEN-bit): $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "  FAIL $f"; done
[ "$fail" -eq 0 ]
