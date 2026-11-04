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
| Fleet on the GPU | **blocked**: never finished on the device | see "GPU findings" |
| RV64 userspace (compiler-rt builtins, musl 1.2.5, busybox 1.36.1) | verified | busybox: ELF64, soft-float `e_flags` = 0, all 296,746 instructions are 4 bytes, no FP |
| RV64 kernel (Linux 6.12.115, rv64ima, SMP, virtio-mmio blk/net) | partial: script and config written; kernel step never ran | `scripts/build-linux64.sh`, `platform/linux64.config` |
| RV64 hart in Bend | not started | — |
| RVC expander (`src/rvc.bend`, `C.expand`) | partial: passes `bend --check-only`; untested | — |
| F/D soft-float in Bend | not started | — |
| SMP, copy-on-write snapshots, virtio devices, Fork-Jacobi replay | designed in `DESIGN.md`; not started | — |

## GPU findings (L4, sm_89, 23 GB, driver CUDA 13.3)

- **Setup:** Bend compiles the device program at runtime with NVRTC. It
  needs `cuda-nvrtc-dev`, `cuda-driver-dev` and `cuda-cudart-dev` (13.3)
  under `/usr/local/cuda`, plus clang 19.
- **Default memory reservation hangs.** Without `--gpu`, the runtime
  reserves the whole device as managed memory: the main thread stalled in a
  23.7 GB `mmap` inside `cuMemAllocManaged`. With `+RTS --gpu 1GB`, `pow2!`
  ran correctly. Always pass an explicit `--gpu` size.
- **The fleet never finished on the device.**
  - With `--gpu 4GB`, fleets of 4 and 16 machines (128 MiB RAM each)
    printed nothing within 240 s.
  - With RAM cut to 64 KiB per machine, a fleet of 2 still timed out after
    200 s. Then the tunnel closed.
  - The same 16-machine fleet on the CPU pool (`--gpu off`, 17 threads):
    256M guest instructions in 766 ms.
- **Hypotheses, none tested:**
  1. One lane per machine running a long serial interpreter loop is very
     slow on the device (the Bend guide puts a lane at about 1/75 of a
     P-core on serial work). The 2M-instruction epoch budget may just be
     minutes per epoch.
  2. Managed-memory page migration on first touch of each machine's RAM.
  3. The device stack or continuation limits for the deep, non-forking
     `epoch -> slice -> run -> step` chain.

  The first measurement to take: a 1,000-instruction budget with 1 and 64
  machines, to get per-lane MIPS.

## Next steps, in order

1. **GPU bring-up** (needs a GPU box): per-lane MIPS as above, then size
   the epoch budget and machine RAM to fit; keep `--gpu` explicit. If lanes
   are too slow for one machine per lane, change the decomposition: split
   one hart's step across a warp (decode / execute / memory as separate
   lanes over a batch of harts), or run many short epochs per bang.
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
