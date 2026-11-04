# wiltee design

wiltee runs a RISC-V machine as a pure function written in Bend 2, with the
goal of executing guests on GPUs. This note explains the shape of the design,
why it departs from the conventional "one thread interprets one CPU" emulator,
and what is built versus planned.

## What exists today

- One RV32IMA hart (Zicsr, Zifencei), S and U modes, Sv32 paging with a
  software TLB, a 16550 UART, a PLIC, and an SBI 1.0 firmware interface
  (BASE, TIME, IPI, RFENCE, HSM, SRST, legacy console) answered by the
  emulator itself: there is no M-mode in the guest. `src/hart.bend`.
- It boots an unmodified Linux 6.12 (semu's prebuilt rv32ima kernel and
  busybox initramfs) to a login prompt and an interactive shell.
- It passes the official riscv-tests rv32ui, rv32um and rv32ua suites
  (59 tests; `ma_data` is excluded because misaligned accesses trap, as in
  semu).
- A fleet of independent machines runs as one fork tree per epoch
  (`H.Fleet.epoch!`), the GPU entry point. `src/fleet.bend`.
- The whole machine is checked by Bend with no `@unsafe`: every `epoch` is
  proven to halt. Only the IO drivers (`src/wiltee.bend`, `src/fleet.bend`)
  use `@unsafe`, for their unbounded host loops.

## Why not the conventional design

A conventional GPU emulator (glae was one) maps each guest CPU to a GPU
thread running a fetch-decode-execute loop over shared global memory, with
atomics for coherence, a persistent kernel that never returns, and the GPU
clock as guest time. Each of those choices assumes a sequential machine:

- Shared mutable memory touched by many lanes means atomics and fences on
  every access that might race, and a memory model the emulator cannot
  express in a fork-join language anyway.
- A persistent kernel fights the GPU's execution model (kernels are meant to
  finish) and needs ad hoc host polling for IO.
- Using the GPU clock as guest time couples guest behaviour to emulator
  speed: a lane that is descheduled freezes the guest's clock (glae's WFI
  hang), and nothing is reproducible.

wiltee instead takes the constraints of Bend's runtime (pure, affine,
binary fork-join, flat loops at the leaves, no sharing between lanes) as the
design, and shapes the machine to fit them.

## Core ideas

### 1. The machine is a value

A hart is an affine record: registers, RAM, CSRs, device words and TLB, all
owned by the hart. `step` executes one instruction; `run(k, h)` executes up
to `k`; `epoch(k, h)` runs slices until a budget is spent. All are total
functions from one machine state to the next. Because arrays are uniquely
owned, every write is in place, yet the program stays pure.

Bend compiles these defs into flat native tail loops: the record rides in
registers, and array reads hand the array back alongside the value, so the
interpreter has no allocation on its hot path.

### 2. Time is the instruction count

`time` advances one tick per retired instruction (`timebase-frequency` is
10 MHz). The consequences:

- Execution is deterministic: the machine is a pure function of its boot
  images and its input bytes. Any run can be replayed exactly.
- Timer interrupts are precise without polling. A slice runs exactly until
  the next deadline, so the hot loop checks only a countdown.
- WFI costs nothing. An idle hart jumps `time` to the next deadline. The
  emulator never spins waiting for a clock, and glae's frozen-clock
  problem cannot occur.
- Wall-clock pacing is a host policy, not a machine property. The
  interactive driver sleeps whenever guest time gets ahead of wall time, so
  `sleep 1` in the guest takes a second while computation runs at full
  speed.

### 3. Epochs: lanes never talk inside a kernel

Execution is bulk-synchronous. An epoch gives every hart a budget and runs
them all to the end of it, with no communication between lanes. Everything
that crosses lanes or touches the outside world happens between epochs, on
the host: console output, keyboard input, and (planned) coherence between
harts of one guest.

Devices whose state is private to a guest live inside its lane: the UART
registers, the PLIC, the timer, and SBI calls all execute in the hart's own
loop. The host only drains a transmit buffer and fills a receive ring
between epochs. A GPU kernel is therefore one epoch over the whole fleet,
and it always finishes.

### 4. Fleets as fork trees

A fleet is a balanced binary tree of machines. `Fleet.epoch` forks at each
node and ends in the flat per-hart loop at each leaf, which is the shape
Bend's GPU scheduler wants: one task per lane, all forked before any runs.
Lanes are balanced because each gets the same instruction budget.

On a machine without a GPU the same bang runs on the CPU pool. Today's
measurement on a 2-vCPU sandbox: 4 machines, 64M guest instructions, 3.28 s
on one thread and 1.82 s on two.

## Planned: several harts in one guest (BSP coherence)

The epoch model extends to SMP without shared mutable memory:

- During an epoch, every hart of a guest reads RAM as it was at the start of
  the epoch. That is a read-only snapshot, so lanes can share it with no
  races and no atomics.
- Each hart buffers its own stores in a private store buffer, which its own
  loads check first.
- At the end of the epoch the buffers are committed in hart order. Because
  the buffers partition by address, the commit is itself a divide-and-conquer
  merge.

This is a valid TSO execution, and therefore valid RVWMO. Every load of an
epoch reads either the epoch-start state or the hart's own earlier store;
every store becomes visible at the commit, in program order; and all harts
see a commit at once, which gives multi-copy atomicity. The only reordering
is a store followed by a later load, which TSO allows.

Operations that need a global order end the hart's epoch early, and the
commit phase executes them serially: AMOs, LR/SC, fences that order stores
before loads, and IPIs and remote fences. The epoch boundary is also the
natural point to exchange IPIs and HSM state. A guest with one hart skips all
of this, which is what runs today.

## Planned: copy-on-write snapshots

The same overlay mechanism — a shared read-only base plus a private
per-lane write log — allows forking a booted machine into thousands of
copies that share its RAM. Memory then stops being the limit on fleet size
(today every machine owns 128 MiB). It is the natural engine for fuzzing,
regression runs and what-if exploration.

## Fork-Jacobi block parallelism (parallel-in-time): assessment

Idea:
1. Cut one hart's instruction stream into N blocks of equal instruction
   count.
2. Guess each block's starting state.
3. Run all blocks in parallel (fork).
4. Feed each block the previous block's end state and repeat (Jacobi) until
   nothing changes.

How it fits wiltee:

- **Structurally, very well.** It is pure fork-join followed by a
  deterministic fixed point. Because time is the instruction count, blocks
  cut by instruction count have fully determined timer behaviour given their
  input state. A wall-clock time base would break that.
- **As the main engine for one hart moving forward, it gains nothing.** A
  CPU step has no contraction: the next state depends on every bit of pc,
  registers and memory it touches. With naive guesses, each iteration fixes
  about one block, so N lanes do about N times the work for sequential
  progress.
- **It pays off when the guesses are good.** A block should be accepted when
  every location it read matches its predecessor's writes (read-set
  validation over the copy-on-write overlays above), not when whole states
  match. Good guesses come from a previous run of the same boot, or from a
  forked snapshot with small input changes. Replay, regression and fleet
  workloads then converge in about one iteration and parallelise almost
  perfectly.
- **Cold, it helps only where the state is overwritten regardless of input:**
  trap entry, memset/memcpy, idle loops.

Recommendation: build it as a replay and fleet accelerator on top of the
overlay layer, after BSP coherence. Do not use it as the primary execution
engine.

## Bend notes

- RV32 rather than RV64: Base offers `U32` and `F32` only. 64-bit
  arithmetic would cost a limb pair on every operation. `mulh*` uses
  16-bit limbs.
- A `match` may only inspect parameters, and an array read returns the array
  with the value. So multi-step logic is a chain of small defs that each
  take the previous result as a parameter (`R2`, `R3` and `Wk` bundle these
  results).
- Defs are declared before use, and mutual recursion is impossible without
  `@unsafe`. The hart keeps to both rules, so its termination is proven.
- Bend's installed Base (2.0.39) has no `Array.get_unchecked`; the wrap mask
  on each array access is one AND.

## Limitations

- Not yet run on a GPU: this environment has no CUDA device. The `!` path is
  exercised on the CPU pool.
- One hart per guest; no virtio, so no block device or network.
- Misaligned loads and stores trap (as in semu; Linux copes).
- No F/D/C extensions.
- The guest kernel and initramfs are semu's prebuilt artifacts, fetched by
  `scripts/fetch-linux.sh`.
