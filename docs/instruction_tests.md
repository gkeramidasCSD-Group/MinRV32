# Instruction tests and build flow

Directed assembly programs under `tests/isa/` exercise every instruction in the supported RV32I subset. Each test writes a deterministic 32-bit signature to the scratch region at DMEM address `0x2000_0100`, and an accompanying `.sig` file captures the expected words.

If you want the end-to-end "simulate -> waves -> asm/C tests -> FPGA validation" walkthrough, start with: [Learning path](learning_path.md).

## Workflow

1. Build and convert the test to hex (`scripts/build_prog.sh` handles both instruction/data images and accepts `.S` or `.c` sources).
2. Use `sim/tb_minrv32.vhd` to preload the instruction/data memories with those hex files, run the pipelined core, and read the signature window after a configurable number of cycles.
3. Compare the observed signature against the expected `.sig`. The expected words come from the Spike ISA simulator (see [Golden signatures with Spike](#golden-signatures-with-spike)).

Scripts are provided to automate these steps with GHDL:

- `scripts/run_test.sh [--trace] <name>` - compile `tests/isa/<name>.S` or `.c`, run the testbench, and stop on the first signature mismatch. Use `--trace` to print per-instruction traces. Override `MAX_CYCLES` in the environment if a test requires more cycles.
- `scripts/run_test.sh [--fst|--vcd|--wave] <name>` - also dumps a waveform under `build/waves/` so you can inspect the pipeline in GTKWave (or other viewers).
- `FORWARDING_ENABLE=false scripts/run_test.sh <name>` - disable forwarding and use stall-only hazards (useful for debugging or verifying hazard handling).
- `scripts/run_tests.sh [--trace] [--verbose]` - iterate over every test with a `.sig` file in `tests/isa/` (both `.S` and `.c` sources) and call `run_test.sh` for batch regressions. All tests run to completion; a pass/fail summary is printed at the end. Pass `--trace` to enable tracing for all tests.
- `scripts/gen_golden.sh [--write|--check] <name>` - run `tests/isa/<name>.S` or `.c` on the Spike ISA simulator and produce its golden signature (see [Golden signatures with Spike](#golden-signatures-with-spike)).
- `scripts/check_goldens.sh` - re-check every checked-in `.sig` file against Spike.
- `scripts/clean.sh` - remove build outputs (`build/`, `work-obj*.cf`) so you can start from a fresh tree.

See [Scripts overview](scripts.md) for a quick reference of every helper script.

## Available smoke tests

- `addi_only` - minimal first test; exercises only ADDI.
- `alu_ops` and `alu_imm` - cover the OP/OP-IMM arithmetic-logical instructions.
- `load_store` - exercises byte/half/word loads plus SB/SH/SW alignment.
- `lui_auipc` - verifies absolute and PC-relative address materialization.
- `branch_jump` - checks JAL/JALR and all six branch encodings.
- `factorial` - a C program that tests recursive function calls, stack usage, and arithmetic.
- `full_core` - a higher level C program that hammers arithmetic, logic, load/store, and control flow as an integration test.

A new test is picked up automatically: `run_tests.sh` runs every test that has a
`tests/isa/<name>.sig` file next to a `<name>.S` or `<name>.c` source.

## Running the `full_core` C program

`tests/isa/full_core.c` is a self-contained bare-metal workload that mimics the shape of real firmware: it brings its own `_start` stub, initializes the stack pointer, exercises many instruction combinations, and finally writes a 9-word signature to `0x2000_0100`. Run it (and any future C-based tests) with the existing script:

```
./scripts/run_test.sh full_core
```

The script compiles the C file, converts it to instruction/data hex images, launches the GHDL testbench, and stops on the first signature mismatch against `tests/isa/full_core.sig`. Override `MAX_CYCLES` if you need more runtime.

Once a test passes under GHDL, you can also load the same `build/full_core.text.hex` / `build/full_core.data.hex` images into an interactive DigitalJS schematic of the full pipeline and step through it cycle-by-cycle in the browser. See [Learning path -- step 5](learning_path.md#5-step-through-the-full-pipeline-in-digitaljs-with-firmware-loaded) and [Scripts overview -- memory initialization for DigitalJS](scripts.md#memory-initialization-for-digitaljs).

## Optional per-instruction trace logging

The testbench can emit a per-cycle pipeline snapshot that shows the state of
all five pipeline stages simultaneously. Each trace block is printed once per
clock cycle and contains lines from **different** pipeline stages -- meaning
different instructions appear on different lines of the same block. This uses
simulation-only wrappers (`sim/riscvpipe_trace.vhd`, `sim/top_trace.vhd`) so
the synthesizable RTL remains unchanged.

Enable tracing with `--trace`:

```
scripts/run_test.sh --trace full_core
```

The GHDL compile list already includes the trace wrappers, but if you run GHDL
manually ensure `sim/top_trace.vhd` and `sim/riscvpipe_trace.vhd` are
compiled before `sim/tb_minrv32.vhd`.

### Understanding the trace: annotated pipeline snapshot

Each trace block is a snapshot of the pipeline at one clock edge. The lines
tap **different pipeline stages**, and each line is annotated with the
instruction that is actually **in** that stage:

| Trace line | Pipeline stage | Signal source |
|---|---|---|
| `ASM=` + `FETCH:` | Fetch/Decode boundary | InstrD, PCF |
| `DECODE [instr]:` | Decode (D) | ImmSrcD |
| `EXEC [instr]:` | Execute (E) | SrcASelE, ALUSrcBE, ALUControlE |
| `MEM [instr]:` | Memory (M) | MemWriteM, MemReadM, MemSizeM |
| `WB [instr]:` | Writeback (W) | ResultSrcW, RegWriteW |
| `HAZARD [instr]:` | Hazard unit (E) | ForwardAE, ForwardBE, StallF/D, FlushD/E |

The `[instr]` annotation on each line shows exactly which instruction occupies
that pipeline stage. Flushed/empty pipeline slots appear as `[---]`. The
`HAZARD:` line is annotated with the E-stage instruction because forwarding
and stall decisions are made for the instruction in Execute.

### Worked example

Given these instructions in program order:

```
0x00: lui x5, 0x20000000        (instr 1)
0x04: addi x5, x5, 256          (instr 2)
0x08: addi x6, x0, 5            (instr 3)
```

When instr 3 enters Decode, the trace block is:

```
ASM=addi x6, x0, 5
FETCH: PC=0x0000000C INSTR=0x00500313
DECODE [addi x6, x0, 5]: ImmSrc=I
EXEC [addi x5, x5, 256]: SrcA=rs1 ALUSrc=imm ALUControl=add
MEM [lui x5, 0x20000000]:
WB [addi x0, x0, 0]: ResultSrc=alu RegWrite=yes
HAZARD [addi x5, x5, 256]: StallF=run StallD=run FlushD=keep FlushE=keep FwdA=M FwdB=rf
```

The `HAZARD [addi x5, x5, 256]: FwdA=M` means: `addi x5, x5, 256` is in the
Execute stage and needs `x5` from its rs1. `lui x5` is in the Memory stage
and has the result, so the hazard unit forwards from M.

### Hazard signal reference

The `HAZARD:` line is only printed when at least one field is non-default:

- `StallF/StallD`: `stall` freezes Fetch/Decode; `run` allows them to advance.
- `FlushD/FlushE`: `flush` inserts a bubble/NOP; `keep` leaves the stage intact.
- `FwdA/FwdB`: `rf` uses regfile operands, `M` forwards from Memory stage, `W` forwards from Writeback stage.

Each trace block is separated from other simulator output by a blank line.

## Waveform dumps (GTKWave)

To explore the design with waveforms, add `--fst` (recommended), `--vcd`, or `--wave`:

```sh
./scripts/run_test.sh --fst alu_ops
gtkwave build/waves/alu_ops.fst
```

If you want smaller waveforms, lower the simulation budget with `MAX_CYCLES` (for example, `MAX_CYCLES=200 ./scripts/run_test.sh --fst alu_ops`).

## Unit-level component testbenches

The ISA tests are integration tests. For quick module bring-up and waveform exploration, small self-checking unit testbenches live under `sim/unit/`:

```sh
./scripts/run_unit_tb.sh alu
./scripts/run_unit_tb.sh --fst regfile
```

Current unit testbenches:

- `sim/unit/tb_alu.vhd`
- `sim/unit/tb_regfile.vhd`
- `sim/unit/tb_mem_access_unit.vhd`
- `sim/unit/tb_hazard_unit.vhd`

## Authoring additional C tests

You can author new freestanding C tests in `tests/isa/` by following the pattern used in `full_core.c`:

1. Provide a tiny `_start` in inline assembly that sets up the stack at the top of DMEM by loading `__stack_top` from the linker script (default `0x2000_2000` for an 8 KiB DMEM) and jumps to `main`. The snippet near the top of `full_core.c` is reusable:

   ```c
   __asm__ (
     ".section .init\n"   /* placed first in IMEM by the linker script */
     ".globl _start\n"    /* entry point symbol referenced by -e _start */
     "_start:\n"
     "  la sp, __stack_top\n"  /* set stack pointer to top of DMEM (from link.ld) */
     "  jal ra, main\n"        /* call main(); ra holds the return address */
     "1: j 1b\n"               /* local label 1, jump-back-to-1: infinite loop if
                                   main() ever returns, preventing runaway execution */
   );
   ```

   Key points:
   - `.section .init` ensures this stub appears at address `0x0000_0000` (the reset vector) because the linker script places `.init` first inside the IMEM region.
   - `la sp, __stack_top` expands to `lui`+`addi` or `auipc`+`addi` depending on relocation; it loads the linker-defined symbol `__stack_top` into `sp` so C code has a valid stack.
   - `jal ra, main` performs a call: it saves the return address in `ra` and jumps to `main`.
   - `1: j 1b` is a *local numeric label* loop. `1b` means "label `1` searching backwards", so this is `j self` -- an infinite spin loop. If `main` returns (it shouldn't in a bare-metal test), this traps the PC here instead of letting it execute arbitrary memory contents.
2. Include `<stdint.h>` only; assume no libc/runtime. Keep everything freestanding and write to the signature buffer through a `volatile uint32_t *` mapped at `0x2000_0100`.
3. Implement deterministic workloads using only the supported RV32I subset - stick to integer math and memory, avoid division or CSR/system calls.
4. Emit final observation words into the signature window (as `full_core.c` does with `sig[0]`, `sig[1]`, ...) so the testbench can compare them against a `.sig` file you capture from a golden simulation.
5. Generate the expected results with Spike: `./scripts/gen_golden.sh --words N --write <test>` writes the `N` words of the signature buffer (`0x2000_0100`) to `tests/isa/<test>.sig` (see [Golden signatures with Spike](#golden-signatures-with-spike)). Do not write raw code or `.rodata` addresses into the signature; see [code-address differences](#golden-signatures-with-spike-code-address-differences). Once the file exists, `scripts/run_test.sh <test>` can regress it automatically.

These steps keep every C program completely freestanding, meaning they can run on the RTL core, in GHDL, or on any other RV32I platform that provides the same memory map and signature buffer.

## Golden signatures with Spike

The expected `.sig` words are produced by [Spike](https://github.com/riscv-software-src/riscv-isa-sim), the RISC-V reference ISA simulator. Spike is independent of the RTL, so it acts as the oracle for the design under test. Do not use a host (x86) build of a C test as the oracle, because 32-bit overflow and shift behavior may differ from RV32I.

```sh
./scripts/gen_golden.sh factorial                 # print words, save build/golden/factorial.sig
./scripts/gen_golden.sh --check factorial         # compare with tests/isa/factorial.sig
./scripts/gen_golden.sh --words 4 --write my_test # new test: write tests/isa/my_test.sig
./scripts/check_goldens.sh                        # check every tests/isa/*.sig
```

`gen_golden.sh` does the following:

1. Builds the test with `build_prog.sh` (same compiler flags as the core) and the Spike linker script `link_spike.ld`, giving `build/<name>.spike.elf`.
2. Runs Spike in debug mode for `SPIKE_MAX_INSNS` instructions (default 1000000). Every test ends in a self-loop, so the script then checks that the PC no longer changes. If it still changes, the program has not finished and the script stops with an error.
3. Reads `N` words from `0x2000_0100` and writes them to `build/golden/<name>.sig`, one lowercase 8-digit hex word per line. `N` is `--words`, or the line count of the existing `tests/isa/<name>.sig`.

`--write` copies the result to `tests/isa/<name>.sig`. `--check` compares it with that file and lists the differing lines. Spike's command file and output are kept in `build/golden/<name>.spike.{cmd,log}`. Environment variables: `SPIKE` (binary, default `spike`), `SPIKE_ISA` (default `rv32i`), `SPIKE_MAX_INSNS`, plus the `build_prog.sh` variables.

### Golden signatures with Spike: code-address differences

**Why the addresses differ.** Spike reserves the low address space for its debug module (`0x0000_0000`-`0x0000_0FFF`) and boot ROM (from `0x1000`), so instruction memory cannot sit at `0x0` as it does on MinRV32. `gen_golden.sh` therefore links the test with `link_spike.ld`, which moves the code to `0x8000_0000` (Spike's default RAM base). Spike's boot ROM jumps to `_start` there. Data memory does not move.

| Item | MinRV32 (`link.ld`) | Spike (`link_spike.ld`) |
| --- | --- | --- |
| `.init`, `.text`, `.rodata` | `0x0000_0000` | `0x8000_0000` |
| `.data` (preloaded), `.bss` | `0x2000_0000`... | same |
| stack top (`__stack_top`) | `0x2000_2000` | same |
| signature window | `0x2000_0100` | same |

Writing to the signature window is not affected: `sig[i] = value` stores to the same address on both. Only the *value* can differ.

**When a golden word is affected.** A word is affected when the stored value is, or is computed from, the address of code or `.rodata`. Under Spike such a value is larger by `0x8000_0000`, so the golden word does not match the core. Examples:

- a function pointer, e.g. `sig[0] = (uint32_t)&main;`
- the address of a label, e.g. `la t0, label` followed by `sw t0, 0(s0)`
- the address of a string literal or a `const` table (these live in `.rodata`)
- a raw link register after `jal`/`jalr`, or a raw `auipc` result

**When it is not affected.**

- arithmetic and logic results
- values loaded *from* `.rodata` (the contents, not the address), as in `lui_auipc.S`
- addresses in data memory (`.data`, `.bss`, stack pointers)
- differences between two code addresses, as in `branch_jump.S` (`x1 - jal_return`)

**How to write such tests.** Store an offset from a known code symbol instead of the raw address, e.g. `(uint32_t)&f - (uint32_t)&_start`. The offset is the same under both links. For example, a program that stores `(uint32_t)_start + 4` and `(uint32_t)&main - (uint32_t)_start` gives `00000004 00000010` on the core and `80000004 00000010` on Spike.

**How to spot the problem.** If `--check` (or `run_test.sh`) reports a word that differs by exactly `0x8000_0000`, a code address has leaked into the signature.

Moving the core's code to `0x8000_0000` would remove this difference; see [Future work: one memory map for the core and Spike](memory_map.md#future-work-one-memory-map-for-the-core-and-spike).

### Golden signatures with Spike: other differences

Code addresses are not the only possible difference. In the cases below, Spike and the core run the same program differently, so a golden word can differ even though both run the same ELF code. None of the current tests hits them.

**Register values at `_start`.** Spike starts in its boot ROM, which leaves values in three registers before it jumps to `_start`. On the core every register is `0` after reset.

| Register | MinRV32 | Spike |
| --- | --- | --- |
| `t0` (`x5`) | `0x0000_0000` | `0x8000_0000` (the entry address) |
| `a0` (`x10`) | `0x0000_0000` | `0x0000_0000` (`mhartid`) |
| `a1` (`x11`) | `0x0000_0000` | `0x0000_1020` (device-tree address) |
| all others | `0x0000_0000` | `0x0000_0000` |

A test that reads `t0` or `a1` before writing it gets different values. Write every register before you read it; do not rely on reset values.

**Cases the core does not trap but Spike does.** The core has no exceptions. Spike raises an exception in the cases below. Because `mtvec` is `0`, the trap handler address is in the debug-module region, so Spike stays at PC `0x0000_0000` from then on.

| Case | MinRV32 | Spike |
| --- | --- | --- |
| Misaligned `lh`/`lhu`/`lw`/`sh`/`sw` | Ignores the low address bits: a word access uses the aligned word, a halfword access uses address bit 1. Example: `lw` from `0x2000_0109` reads the word at `0x2000_0108`. | Misaligned-access exception |
| Access outside the memory windows (IMEM 8 KiB at `0x8000_0000` on Spike, DMEM 8 KiB at `0x2000_0000`) | Wraps the address into the 8 KiB array: `0x2000_2000` reads `0x2000_0000`. Loads below `0x2000_0000` read IMEM; stores always write DMEM, so a store to a code address overwrites a DMEM word. | Access-fault exception |
| `ecall`, `ebreak`, other undecoded instructions | No-op | Exception (environment call, breakpoint or illegal instruction) |

CSR instructions (`csrr`, `rdcycle`, ...) do not assemble with `-march=rv32i`, so they cannot reach either simulator.

**How to spot a trap.** `gen_golden.sh` does not detect a trap: the trap loop at PC `0x0` looks like the final self-loop, so the script reads whatever the signature window holds at that point, often zeros. Look at `build/golden/<name>.spike.log`. After a normal run the two PC values are an address in `0x8000_xxxx` (the final `j .` loop); after a trap they are `0x00000000`.

### Running a program on Spike by hand

Spike does not compile anything. It is an instruction-set simulator: it loads an ELF file of RISC-V machine code and executes it one instruction at a time. A C or assembly source is first compiled and linked by the RISC-V GCC toolchain, and the resulting ELF is then run on Spike. `gen_golden.sh` does these steps for you. To do them by hand, run from the repository root:

```sh
# 1. Compile and link for Spike (code at 0x8000_0000, see the table above).
#    Works for .c and .S sources; writes build/factorial.spike.elf.
LINKER_SCRIPT=$PWD/link_spike.ld ./scripts/build_prog.sh tests/isa/factorial.c factorial.spike

# 2. Look at the machine code and the symbol addresses.
riscv64-unknown-elf-objdump -d build/factorial.spike.elf | less
riscv64-unknown-elf-nm build/factorial.spike.elf      # e.g. 80000000 T _start, 80000068 T main

# 3. Start Spike in its interactive debugger.
spike -d --isa=rv32i -m0x80000000:0x2000,0x20000000:0x2000 build/factorial.spike.elf
```

| Option | Meaning |
| --- | --- |
| `-d` | start in the interactive debugger, halted before the first instruction |
| `--isa=rv32i` | simulate the same base ISA as the core |
| `-m0x80000000:0x2000,0x20000000:0x2000` | two 8 KiB memories: code at `0x8000_0000`, data at `0x2000_0000` (the MinRV32 DMEM, so the signature window is at `0x2000_0100`) |

Notes:

- Spike prints `warning: tohost and fromhost symbols not in ELF; can't communicate with target`. This is expected. The tests are freestanding and have no host interface, so there is no `printf` output; results are read from the signature window.
- The tests never exit; they end in a self-loop. Without `-d`, Spike runs forever. Use the debugger, or stop it with Ctrl+C.
- The same commands can be put in a file and run in batch with `--debug-cmd=<file>`. `gen_golden.sh` works this way, and its command file is kept in `build/golden/<name>.spike.cmd`.

### Stepping through a program in Spike's debugger

After `spike -d ...` starts, Spike shows a `:` prompt and waits. Execution begins in Spike's boot ROM at `0x1000`. The boot ROM runs five instructions and then jumps to `_start` at `0x8000_0000`. Most commands take a core number, which is always `0` here. Type `help` to list all commands.

| Command | What it does |
| --- | --- |
| Enter | run one instruction and print it (same as `run 1`) |
| `run N` / `r N` | run `N` instructions, printing each one |
| `rs N` | run `N` instructions silently |
| `run` | run until Ctrl+C, which returns to the prompt |
| `pc 0` | show the current PC |
| `insn 0` | show the instruction at the current PC |
| `reg 0` / `reg 0 a0` | show all registers, or one register (ABI names such as `sp`, `ra`, `a0` work) |
| `mem 0x20000100` | show memory at a physical address (here, signature word 0) |
| `until pc 0 0x80000068` | run silently until the PC reaches an address (here, `main`) |
| `untiln pc 0 0x80000068` | the same, but print each instruction |
| `until reg 0 a0 0x2d0` | run until a register holds a value |
| `until mem 0x20000100 0x2d0` | run until a memory word holds a value |
| `q` | quit |

Take the addresses for `until pc` from the `nm` or `objdump` output of step 2. A short session with `factorial.c` looks like this; Spike's output is shown after each command, and lines starting with `#` are comments:

```text
: pc 0
0x00001000                              # in the boot ROM
: r 3
core   0: 0x00001000 (0x00000297) auipc   t0, 0x0
core   0: 0x00001004 (0x02028593) addi    a1, t0, 32
core   0: 0x00001008 (0xf1402573) csrr    a0, mhartid
: until pc 0 0x80000068                 # run to main
: insn 0
0xff010113 addi    sp, sp, -16
: reg 0 sp
0x20002000                              # stack top set by _start (__stack_top)
: reg 0 ra
0x8000000c                              # return address: the self-loop in _start
: r 2
core   0: 0x80000068 (0xff010113) addi    sp, sp, -16
core   0: 0x8000006c (0x00600513) li      a0, 6
: until mem 0x20000100 0x2d0            # run until sig[0] = 6! is stored
: pc 0
0x80000080                              # the instruction after the store
: mem 0x20000100
0x000002d0                              # the value in tests/isa/factorial.sig
: q
```

The PCs Spike prints are `0x8000_0000` higher than on the core, because of the Spike link; the instructions and the data values are the same. To compare with the core cycle by cycle, run the same test with `./scripts/run_test.sh --trace factorial`. It prints the same instructions as they pass through the five pipeline stages, at addresses starting from `0x0`.

## Prerequisites

The install commands for every tool, with and without `sudo`, are on the
[Prerequisites](prerequisites.md) page.

## Turnkey build workflow

The repository ships with a linker script (`link.ld`) that maps `.text/.rodata` to the instruction memory region at `0x00000000` and `.data/.bss` to the data memory window at `0x2000_0000`. Use `scripts/build_prog.sh` to compile any `prog.c` and emit ready-to-load hex images:

```
./scripts/build_prog.sh path/to/prog.c [base_name]
```

Outputs are written to `build/`:

- `<base>.elf` - full ELF for debug/symbol inspection.
- `<base>.text.hex` - 32-bit words for instruction memory initialization (text+rodata).
- `<base>.data.hex` - 32-bit words for data memory initialization (.data/.sdata). The provided memories power up cleared, so `.bss` stays zeroed automatically.
- `<base>.S` (for `.c` sources) - GCC's assembly listing so you can inspect the generated RV32I instructions.

Both hex files use one 32-bit word per line, matching the `imem` and `dmem` simple models (for example via `$readmemh` or FPGA BRAM initializers). Adjust `RISCV_GCC`, `RISCV_OBJCOPY`, `CFLAGS`, or `LDFLAGS` environment variables to point at a different toolchain or tweak optimization options.

## GCC flags (what `build_prog.sh` is optimizing for)

`scripts/build_prog.sh` uses a set of conservative "bare-metal friendly" flags so the compiler and linker don't assume an OS, libc, or unsupported ISA extensions. The exact defaults live in the script, but conceptually it's equivalent to:

```sh
riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -Os \
  -ffreestanding -nostdlib -fno-builtin \
  -fno-pic -mcmodel=medlow \
  -fno-asynchronous-unwind-tables -fno-stack-protector \
  -Wl,-e,_start -Wl,--gc-sections -Wl,--build-id=none \
  -T link.ld prog.c -o prog.elf
```

What the key flags do:

- `-march=rv32i` / `-mabi=ilp32` keep codegen within the implemented ISA/ABI.
- `-ffreestanding -nostdlib -fno-builtin` prevent dependencies on a hosted runtime/libc.
- `-fno-pic -mcmodel=medlow` keep addresses/linking simple for a fixed memory map.
- `-fno-asynchronous-unwind-tables -fno-stack-protector` avoid extra runtime metadata/helpers.
- `-Wl,-e,_start` selects your startup entry point; `--gc-sections` drops unused code.
- `-Wl,--build-id=none` stops the linker from adding a build-ID note section.
  Some toolchains add one by default, for example the RISC-V GCC that comes
  with AMD Vitis (sourcing Vivado's `settings64.sh` puts it first in `PATH`
  when Vitis is installed). The linker scripts also discard such sections,
  and they stop the link with an error if `.text` does not start at the
  start of IMEM.
- `-T link.ld` selects the linker script, which places code at the
  instruction memory and data at the data memory (see
  [Memory map](memory_map.md)).

If you need to change codegen (for example to work around missing instructions, or to change optimization level), override `CFLAGS`/`LDFLAGS` when invoking `build_prog.sh`/`run_test.sh`.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
