#!/bin/bash
# RV64 GPU fleet sweep: 2^d machines each running tests/bare/fleet64.S
# (4,000,021 guest instructions, 64 KiB of RAM) in two modes:
#   run   the whole run is one bang (H.Fleet.run!): the host is not in the loop
#   step  one bang per epoch of 1M instructions, the host drains in between
# Every machine's result is checked against tests/bare/fleet64.py.
# Keep --gpu at 1GB (larger reservations stall in the driver's mmap on the L4).
set -u
cd "$(dirname "$0")/../.."
make build/fleet64.bin build/fleet64 >/dev/null || exit 1
for d in ${DEPTHS:-0 6 8 10 12}; do
  python3 tests/bare/fleet64.py $((1 << d)) > build/fleet64.want
  for mode in ${MODES:-run step}; do
    out=$(timeout 1500 ./build/fleet64 build/fleet64.bin "$d" "$mode" +RTS ${RTS:---gpu 1GB} -RTS)
    ok=$(grep '^vm' <<<"$out" | cut -c1-36 | sort | diff -q - <(sort build/fleet64.want) >/dev/null && echo results-ok || echo RESULTS-WRONG)
    echo "machines=2^$d mode=$mode: $(tail -1 <<<"$out") [$ok]"
  done
done
