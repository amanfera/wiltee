#!/usr/bin/env bash
# Checks the virtio-mmio devices (src/virtio.bend): the module has no @unsafe
# and proves total (ALL PROOFS CHECK), then tests/virtio/virtio_test.bend,
# a simulated Linux driver, is built and run. Prints a PASS/FAIL line per
# check and exits non-zero if anything failed. OUT picks the build directory.
set -euo pipefail
cd "$(dirname "$0")/../.."
BEND=${BEND:-bend}
OUT=${OUT:-build/virtio}
mkdir -p "$OUT"

if grep -nE '@unsafe|^def [^(]*\?\(' src/virtio.bend; then
  echo "FAIL src/virtio.bend must not be @unsafe"; exit 1
fi
$BEND src/virtio.bend --check-only > "$OUT/check.log" 2>&1 || true
if grep -q 'ALL PROOFS CHECK' "$OUT/check.log"; then
  echo "PASS bend src/virtio.bend --check-only: ALL PROOFS CHECK"
else
  cat "$OUT/check.log"; echo "FAIL bend src/virtio.bend --check-only"; exit 1
fi

# The driver prints through IO (foreign code), so bend's exit status says
# nothing; judge the build by the binary it leaves behind.
rm -f "$OUT/virtio_test"
$BEND tests/virtio/virtio_test.bend -o "$OUT/virtio_test" > "$OUT/build.log" 2>&1 || true
test -x "$OUT/virtio_test" || { cat "$OUT/build.log"; echo "FAIL build of tests/virtio/virtio_test.bend"; exit 1; }

status=0
"$OUT/virtio_test" || status=$?
if [ "$status" -ne 0 ]; then
  echo "virtio: FAILED"; exit 1
fi
echo "virtio: PASS"
