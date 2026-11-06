#!/usr/bin/env bash
# Checks src/fpu.bend against Berkeley SoftFloat 3e built with the RISC-V
# specialization, through TestFloat 3e's testfloat_gen.
#
# Fetches and builds SoftFloat and TestFloat (pinned revisions) under
# build/fpu/ when missing, builds the native driver tests/fpu/fpu_test.bend,
# then runs every TestFloat function that maps onto the FPU interface at
# -level 1 (-tininessafter, -exact) in each rounding mode it takes, plus the
# FMIN/FMAX/FCLASS vectors of tests/fpu/special.py (cross-checked against
# riscv-tests).
#
#   tests/fpu/run.sh            level 1: about 63M vectors
#   tests/fpu/run.sh --level2   also level 2 for add/sub/mul/div/sqrt and two
#                               more seeds of level 1 for mulAdd (~1.1G vectors)
#
# Prints pass/fail counts per function and rounding mode, and the first
# failing vector of any failing run. Exits 0 only if every vector matches
# exactly (result bits and flags). JOBS sets the parallelism (default: nproc).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/build/fpu
SOFTFLOAT_REV=07ebd29db0cfb55723a79fbbffe99103ef38e305   # ucb-bar/berkeley-softfloat-3
TESTFLOAT_REV=a9c849f1b0eb0264b626d9686ffae167d996e3be   # ucb-bar/berkeley-testfloat-3
RISCV_TESTS_REV=3df703cd52d5f0d8224e3c50bf03c6cb70efff98 # riscv-software-src/riscv-tests
PLATFORM=${PLATFORM:-Linux-x86_64-GCC}
JOBS=${JOBS:-$(nproc)}
BEND=${BEND:-bend}

LEVEL2=0
case "${1:-}" in
  --level2) LEVEL2=1 ;;
  "") ;;
  *) echo "usage: $0 [--level2]" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
START=$(date +%s)

# fetch DIR URL REV: a shallow checkout of exactly REV
fetch() {
  if [ ! -e "$1/.git" ] || [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" != "$3" ]; then
    echo "fetching $2 @ $3"
    rm -rf "$1"
    git init -q "$1"
    git -C "$1" fetch -q --depth 1 "$2" "$3"
    git -C "$1" -c advice.detachedHead=false checkout -q FETCH_HEAD
  fi
}

SF=$OUT/softfloat
TF=$OUT/testfloat
RT=$OUT/riscv-tests
fetch "$SF" https://github.com/ucb-bar/berkeley-softfloat-3 "$SOFTFLOAT_REV"
fetch "$TF" https://github.com/ucb-bar/berkeley-testfloat-3 "$TESTFLOAT_REV"
fetch "$RT" https://github.com/riscv-software-src/riscv-tests "$RISCV_TESTS_REV"

# SoftFloat with the RISC-V specialization (a stamp records it), then
# TestFloat linked against it.
SFB=$SF/build/$PLATFORM
TFB=$TF/build/$PLATFORM
GEN=$TFB/testfloat_gen
if [ ! -f "$SFB/softfloat.a" ] || [ ! -f "$SFB/.riscv-$SOFTFLOAT_REV" ]; then
  echo "building SoftFloat (SPECIALIZE_TYPE=RISCV)"
  make -C "$SFB" clean >/dev/null
  make -C "$SFB" -j"$JOBS" SPECIALIZE_TYPE=RISCV >"$OUT/softfloat.log" 2>&1 || { cat "$OUT/softfloat.log"; exit 1; }
  touch "$SFB/.riscv-$SOFTFLOAT_REV"
  rm -f "$GEN"
fi
if [ ! -x "$GEN" ]; then
  echo "building TestFloat"
  make -C "$TFB" clean >/dev/null
  make -C "$TFB" -j"$JOBS" SOFTFLOAT_DIR="$SF" PLATFORM="$PLATFORM" >"$OUT/testfloat.log" 2>&1 || { cat "$OUT/testfloat.log"; exit 1; }
fi

# The library must stay total: no @unsafe, every proof checks.
CHECK=$("$BEND" "$ROOT/src/fpu.bend" --check-only 2>&1 || true)
if ! grep -q "ALL PROOFS CHECK" <<<"$CHECK"; then
  echo "$CHECK"
  echo "src/fpu.bend: bend --check-only failed"
  exit 1
fi
echo "src/fpu.bend: ALL PROOFS CHECK"

# The driver. bend exits non-zero for a file whose IO loop is @unsafe, so
# success is judged by the binary it leaves behind.
DRV=$OUT/bin/fpu_test
if [ ! -x "$DRV" ] || [ "$ROOT/src/fpu.bend" -nt "$DRV" ] || [ "$ROOT/tests/fpu/fpu_test.bend" -nt "$DRV" ]; then
  echo "building tests/fpu/fpu_test.bend"
  mkdir -p "$OUT/bin"
  rm -f "$DRV"
  "$BEND" "$ROOT/tests/fpu/fpu_test.bend" -o "$DRV" >"$OUT/bin/build.log" 2>&1 || true
  [ -x "$DRV" ] || { cat "$OUT/bin/build.log"; exit 1; }
fi

python3 "$ROOT/tests/fpu/special.py" "$RT" "$OUT/special"

# Jobs: "<tag> <function> <rm> <level> <seed>", biggest first.
ROUNDING="f32_mulAdd f64_mulAdd f32_add f32_sub f32_mul f32_div f32_sqrt f64_add f64_sub f64_mul f64_div f64_sqrt
  f32_to_i32 f32_to_ui32 f32_to_i64 f32_to_ui64 f64_to_i32 f64_to_ui32 f64_to_i64 f64_to_ui64
  i32_to_f32 ui32_to_f32 i64_to_f32 ui64_to_f32 f64_to_f32
  i32_to_f64 ui32_to_f64 i64_to_f64 ui64_to_f64"
EXACT="f32_eq f32_lt f32_le f64_eq f64_lt f64_le f32_to_f64"
SPECIAL="f32_min f32_max f32_class f64_min f64_max f64_class"
LOGS=$OUT/logs
rm -rf "$LOGS"
mkdir -p "$LOGS"
{
  if [ "$LEVEL2" = 1 ]; then
    for f in f64_add f64_sub f64_mul f64_div f32_add f32_sub f32_mul f32_div f32_sqrt f64_sqrt; do
      for m in 0 1 2 3 4; do echo "L2 $f $m 2 1"; done
    done
    for s in 2 3; do
      for f in f32_mulAdd f64_mulAdd; do
        for m in 0 1 2 3 4; do echo "S$s $f $m 1 $s"; done
      done
    done
  fi
  for f in $ROUNDING; do
    for m in 0 1 2 3 4; do echo "L1 $f $m 1 1"; done
  done
  for f in $EXACT; do echo "L1 $f 0 1 1"; done
  for f in $SPECIAL; do echo "SP $f 0 0 0"; done
} >"$OUT/jobs.txt"

run_one() {
  local tag=$1 f=$2 m=$3 level=$4 seed=$5 mode
  case $m in
    0) mode=rnear_even ;; 1) mode=rminMag ;; 2) mode=rmin ;; 3) mode=rmax ;; *) mode=rnear_maxMag ;;
  esac
  {
    if [ "$tag" = SP ]; then
      "$DRV" "$f" "$m" <"$OUT/special/$f.txt"
    else
      "$GEN" -level "$level" -seed "$seed" -tininessafter -"$mode" -exact "$f" | "$DRV" "$f" "$m"
    fi
  } >"$LOGS/$tag.$f.$m" 2>&1 || echo "ERROR: exit status $?" >>"$LOGS/$tag.$f.$m"
}
export -f run_one
export DRV GEN OUT LOGS
echo "running $(wc -l <"$OUT/jobs.txt") jobs on $JOBS threads"
xargs -P "$JOBS" -L 1 bash -c 'run_one "$@"' _ <"$OUT/jobs.txt"

# Report: one row per function (and test set), one column per rounding mode.
python3 - "$OUT/jobs.txt" "$LOGS" "$(( $(date +%s) - START ))" <<'EOF'
import sys, os
jobs, logs, secs = sys.argv[1], sys.argv[2], sys.argv[3]
names = {"L1": "", "L2": " (level 2)", "S2": " (seed 2)", "S3": " (seed 3)", "SP": " (special)"}
rows, order, total, failed, problems = {}, [], 0, 0, []
for line in open(jobs):
    tag, f, m = line.split()[:3]
    key = f + names[tag]
    if key not in rows:
        rows[key] = {}
        order.append(key)
    text = open(os.path.join(logs, "%s.%s.%s" % (tag, f, m))).read()
    res = [l.split() for l in text.splitlines() if l.startswith("RESULT ")]
    if len(res) != 1 or "ERROR" in text or int(res[0][4]) + int(res[0][3]) == 0:
        rows[key][m] = "ERROR"
        problems.append((key, m, text))
        failed += 1
        continue
    p, x = int(res[0][3]), int(res[0][4])
    total += p + x
    failed += x
    rows[key][m] = "%d/%d" % (p, x) if x else "%d" % p
    if x:
        problems.append((key, m, text))
modes = ["RNE", "RTZ", "RDN", "RUP", "RMM"]
print("\n%-26s" % "passed[/failed]" + "".join("%12s" % h for h in modes))
for key in order:
    print("%-26s" % key + "".join("%12s" % rows[key].get(str(i), "-") for i in range(5)))
for key, m, text in problems:
    print("\n%s %s:\n%s" % (key, modes[int(m)], text.strip()))
print("\n%d vectors, %d failed, in %s s" % (total, failed, secs))
sys.exit(1 if failed else 0)
EOF
