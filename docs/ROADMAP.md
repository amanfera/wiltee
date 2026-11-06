# wiltee roadmap and status

Snapshot as of 2026-11-04. Each item below is labelled verified, partial or
not started.

## Goals

1. Run the whole machine on the GPU. The CPU's role shrinks to an IO pump,
   or as close to that as Bend's host-launched kernels allow.
2. 64-bit guests (RV64), then RV64GC: compressed instructions plus
   floating point.
3. Several harts per guest (SMP), copy-on-write snapshot fleets, virtio
   disk and network.

## Status

| Area | State | Evidence |
|---|---|---|
| RV32IMA hart, Sv32, UART, PLIC, SBI, interactive Linux shell | verified (merged in #1) | 59/59 riscv-tests; `make test-linux` |
| GPU toolchain (CUDA 13.3 NVRTC on an NVIDIA L4) | verified | `pow2!` returned the correct result in 3 ms with `+RTS --gpu 1GB` |
| Fleet on the GPU | **verified**: up to 4096 machines per bang, 1.28 G guest instr/s on an L4 | see "GPU findings" |
| RV64 userspace (compiler-rt builtins, musl 1.2.5, busybox 1.36.1) | verified | busybox: ELF64, soft-float `e_flags` = 0, all 296,746 instructions are 4 bytes, no FP |
| RV64 kernel (Linux 6.12.115, rv64ima, SMP, virtio-mmio blk/net) | partial: script and config written; kernel step never ran | `scripts/build-linux64.sh`, `platform/linux64.config` |
| RV64 hart in Bend | not started | — |
| RVC expander (`src/rvc.bend`, `C.expand`) | partial: passes `bend --check-only`; untested | — |
| F/D soft-float in Bend | not started | — |
| SMP, copy-on-write snapshots, virtio devices, Fork-Jacobi replay | designed in `DESIGN.md`; not started | — |

## GPU findings (L4, sm_89, 23 GB, driver CUDA 13.3)

Setup: Bend compiles the device program with NVRTC at build time and loads
the cubin from `<binary>.gpu` at run time. The box needs:
- `cuda-nvrtc-dev`, `cuda-driver-dev`, `cuda-cudart-dev` (13.3), so that
  `/usr/local/cuda/include/nvrtc.h` exists
- clang 19

**The `--gpu` reservation decides whether anything runs.**
- The runtime takes its whole span as managed memory. The driver populates
  that span page by page on the host CPU.
- Without `--gpu` it asks for the whole device (23.7 GB), and at 1.5 GB or
  more it stalls inside `cuMemAllocManaged -> mmap`. That stall, not the
  emulator, is why the first session's fleets never finished.
- 512 MB to 1 GB starts in about 150 ms. 256 MB is too small for the
  runtime's rings and stacks.
- Use `+RTS --gpu 1GB` (`tests/gpu/sweep.sh` does).

**Measured** with `tests/gpu/bench.bend`: a fleet of 2^d bare-metal machines,
64 KiB RAM each, running an LCG loop. Steady-state timing is the third bang.
The CPU baseline is that box's single core (the container had `nproc` = 1).

| machines | budget/epoch | GPU bang | CPU (1 core) | GPU guest instr/s |
|---|---|---|---|---|
| 1 | 100k | 67 ms | 2 ms | 1.5 M (one lane) |
| 64 | 100k | 106 ms | 16 ms | 60 M |
| 1024 | 10k | 15 ms | 30 ms | 683 M |
| 1024 | 100k | 140 ms | 183 ms | 731 M |
| 4096 | 10k | 35 ms | 77 ms | 1.17 G |
| 4096 | 100k | 320 ms | 522 ms | **1.28 G** |

Reading the numbers:
- **Throughput scales with machine count.** A single lane is about 30x
  slower than a host core.
- **The GPU passes one core at about 1000 machines** and is 1.6–2.2x at
  4096. That is an L4 against one core; this is not yet a win over a
  multi-core host.
- **Per-lane speed drops under load:** 1.5 M instr/s alone, about 0.3 M at
  4096 lanes. That points at memory-bound array access. A Bend `Array` is a
  balanced tree, so every guest load, store or fetch walks log2(size)
  levels: 14 for 64 KiB of RAM, 25 for 128 MiB.
- **16384 machines do not fit in 1 GB.** Each machine carries its own
  device-word array. Its console TX buffer was cut from 64 KiB to 8 KiB to
  get 4096 to fit.

## Next steps, in order

1. **GPU throughput.** Bring-up is done.
   - Cut the per-access tree walk: a flat RAM representation (check whether
     the runtime's native `array_get` is O(1) on the device), or a per-hart
     software cache of recently used RAM pages.
   - Shrink the per-machine fixed footprint so 16384 machines fit in a
     1 GB span.
   - Then re-measure against a multi-core host.
2. **Minimise the CPU's role.**
   - Today: one bang per epoch, and the host does the console and pacing.
   - Target: K epochs per bang, with console bytes kept in a device-side
     ring and the host waking only for IO.
   - Bend launches kernels from the host, so the floor is a thin host loop
     that relaunches and pumps IO; it is not zero.
3. **RV64 hart.**
   - Registers as (hi, lo) U32 pairs; the 64-bit ALU and the `*W` ops.
   - Sv39 three-level walk; 64-bit CSRs, so `time` no longer needs a
     separate high word.
   - RAM moves to 0x80000000 to match the new kernel.
   - Finish `scripts/build-linux64.sh` (the kernel step, about 20 min on 2
     vCPUs), check vmlinux for 2-byte instructions, and boot-test in
     QEMU with `-cpu rv64,c=false,f=false,d=false`.
4. **C extension.**
   - Test `C.expand`: an llvm-mc corpus plus all 49,152 halfwords.
   - Then integrate: 2-byte pc steps, and 32-bit fetches that straddle a
     page.
5. **F/D.**
   - IEEE 754 binary32/binary64 from U32 limbs, with all rounding modes and
     fflags, checked against TestFloat.
   - Then the FP register file, `frm`/`fflags`/`fcsr`, `mstatus.FS`
     dirty tracking, and NaN boxing.
6. **SMP:** epoch snapshot plus per-hart store buffers (TSO), with AMOs,
   LR/SC and IPIs at epoch boundaries; then HSM hart start.
7. **Virtio-mmio** block and network devices (the kernel config already
   enables them), with host-side backends between epochs.
8. **Copy-on-write snapshot fleets**, then the Fork-Jacobi replay
   accelerator on top of them.
