# wiltee

A RISC-V virtual machine written in [Bend 2](https://github.com/bendlang/bend),
designed so the machine maps onto Bend's runtime, which targets GPUs: pure,
affine, fork-join, with no cross-lane sharing. It boots an unmodified Linux
6.12 to an interactive shell.

```
$ make run
[    0.000000] Linux version 6.12.91 ... #1 SMP ...
[    0.000000] Machine model: wiltee
[    0.000000] SBI specification v1.0 detected
...
Welcome to Buildroot
buildroot login: root
# uname -sm
Linux riscv32
```

## What it is

- **Machine:** one RV32IMA hart (Zicsr, Zifencei; S and U modes; Sv32 MMU),
  a 16550 UART, a PLIC, and an SBI 1.0 firmware that the emulator answers
  itself. Source: `src/hart.bend`.
- **A total, pure state transformer:** the machine file has no `@unsafe`,
  and Bend proves that every epoch halts.
- **Deterministic:** guest time is the instruction count, so a run is a pure
  function of its images and its input. Idle time costs nothing, because WFI
  jumps time to the next deadline.
- **Bulk-synchronous:** each epoch runs every hart to a budget with no
  communication between lanes. Console IO and (planned) cross-hart
  coherence happen between epochs.
- **Fleets:** many machines run as one fork tree per epoch
  (`Fleet.epoch!`), the GPU entry point (`src/fleet.bend`).

[docs/DESIGN.md](docs/DESIGN.md) explains the reasoning, the planned SMP
memory model (epoch snapshots plus store buffers, which is TSO-correct),
copy-on-write snapshot fleets, and an assessment of parallel-in-time
(Fork-Jacobi) execution.

## Build and run

Requirements:
- Bend 2.0.39+ (`curl -fsSL https://bend-lang.com/install.sh | sh`)
- clang 14+ for native builds
- `dtc`
- for the tests: an LLVM with RISC-V support (`clang`, `ld.lld`,
  `llvm-objcopy`)

```sh
make            # build/wiltee, build/fleet, platform/wiltee.dtb
make linux      # fetch semu's prebuilt rv32 kernel + busybox initramfs (SHA-1 checked)
make run        # boot it; log in as root (no password). Ctrl-A x quits.
```

`build/wiltee <kernel|-> <dtb|-> <initrd|-> [line ...]` takes optional
lines, which it types at the guest's `login: ` and `# ` prompts. After that
the terminal drives the guest. Set `WILTEE_TRACE=1` to print one state line
per epoch on stderr.

## Tests

```sh
make check       # Bend checks src/hart.bend: ALL PROOFS CHECK
make test-bare   # bare-metal smoke test + a 4-machine fleet
make test-isa    # riscv-tests rv32ui/um/ua against an S-mode env (59 tests)
make test-linux  # boot Linux on a pty, log in, run commands, power off
make test        # all of the above
```

Measured in a 2-vCPU cloud sandbox (CPU-only; no GPU was available):
- **Interpreter speed:** about 60–70 guest MIPS of CPU time on simple loops,
  single-threaded.
- **Linux:** boot to the login prompt takes about 21 s. The full interactive
  test takes 25 s wall and 9 s CPU.
- **Fleet:** 4 machines, 64M guest instructions: 3.3 s on 1 thread, 1.8 s on
  2.

## Layout

```
src/hart.bend      the machine: ISA, MMU, traps, CSRs, SBI, UART, PLIC, slices, epochs, fleets
src/wiltee.bend    the interactive/scripted host driver (file loading, console, pacing)
src/fleet.bend     runs 2^d machines from one image, one bang per epoch
src/tty.c, tty.js  a custom Bend effect: non-blocking raw keyboard input
platform/          the device tree (wiltee.dts and its compiled .dtb)
tests/             bare-metal tests, the riscv-tests environment, the pty Linux test
scripts/           fetch-linux.sh, isa-tests.sh
```

## Limitations

- Not yet run on a GPU.
- One hart per guest.
- No virtio devices.
- No F/D/C extensions.
- Misaligned accesses trap.

See [docs/DESIGN.md](docs/DESIGN.md) for the roadmap.
