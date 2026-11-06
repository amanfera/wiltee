#!/bin/bash
# GPU fleet sweep: builds tests/gpu/bench.bend and times one-bang epochs for
# fleets of 2^d machines. Keep --gpu at 1GB: on the L4 sandbox we measured,
# reservations of 1.5GB and up stall in the driver's managed-memory mmap.
set -u
cd "$(dirname "$0")/../.."
make build/fleet.bin >/dev/null
bend tests/gpu/bench.bend -o build/bench > build/bench.log 2>&1
test -x build/bench || { cat build/bench.log; exit 1; }
for cfg in "0 100000" "6 100000" "10 10000" "10 100000" "12 10000" "12 100000"; do
  set -- $cfg
  echo "=== machines=2^$1 budget=$2"
  timeout 400 stdbuf -oL ./build/bench build/fleet.bin "$1" "$2" +RTS --gpu 1GB -RTS 2>&1
done
