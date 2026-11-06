#!/usr/bin/env bash
# Checks C.expand (src/rvc.bend) against LLVM for all 49,152 RV64C halfwords:
# rebuilds tests/rvc/expand.bend, regenerates the LLVM reference and compares
# (method in compare.py). Needs bend, python3 and llvm-mc 19 (LLVM_MC to pick
# one). Ends with "rvc: 49152 halfwords checked, 0 mismatches" and exit 0.
set -euo pipefail
cd "$(dirname "$0")/../.."
BEND=${BEND:-bend}
LLVM_MC=${LLVM_MC:-$(command -v llvm-mc-19 || command -v llvm-mc)}
OUT=build/rvc
mkdir -p "$OUT"

# The expander stays total: no @unsafe (nor its `def f?` sugar), and it checks.
if grep -nE '@unsafe|^def [^(]*\?\(' src/rvc.bend; then
  echo "rvc: src/rvc.bend must not be @unsafe"; exit 1
fi
$BEND src/rvc.bend --check-only > "$OUT/check.log" 2>&1 || true
grep -q 'ALL PROOFS CHECK' "$OUT/check.log" || { cat "$OUT/check.log"; exit 1; }

# Judge the driver by the binary it leaves behind, as the Makefile does.
rm -f "$OUT/expand"
$BEND tests/rvc/expand.bend -o "$OUT/expand" > "$OUT/expand.log" 2>&1 || true
test -x "$OUT/expand" || { cat "$OUT/expand.log"; exit 1; }
"$OUT/expand" > "$OUT/bend.txt"

python3 tests/rvc/compare.py "$LLVM_MC" "$OUT/bend.txt" "$OUT"
