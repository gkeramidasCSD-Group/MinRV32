# Learning Path (Educational Flow)

This page ties the repo together into a lab-style progression:

1. Simulate VHDL modules with unit testbenches (GHDL)
2. Visualize module behavior with GTKWave waveforms
3. Explore simple modules interactively with DigitalJS (schematic + simulation)
4. Run full-core assembly/C tests under GHDL -> check signature (`.sig`) and/or view waveforms
5. Step through the full pipeline in DigitalJS with real firmware loaded (`--mem-init`)
6. Move to Vivado: XSim simulation, then synthesis/implementation, then ILA-based signature capture on the FPGA

Steps 1, 2, 4, and 6 form the **verification ladder** (signature-checked, authoritative).
Steps 3 and 5 are **visual/interactive companions**: a drag-and-drop, browser-based way to
*see the gates move* while you read the same RTL. They complement GTKWave and Vivado XSim
but do not replace signature-checked regression.

If you get lost, return to the documentation hub in the root README.

---

## 0. Tools (keep it lightweight)

Required (simulation + software build):

- GHDL (VHDL-2008)
- RISC-V bare-metal toolchain (`riscv64-unknown-elf-*`)
- Python 3

Optional (waveforms):

- GTKWave (for `.fst`, `.vcd`, `.ghw`)

Optional (schematics + interactive simulation):

- Yosys + yosys-plugin-ghdl + Graphviz + netlistsvg + yosys2digitaljs (for SVG schematic generation and DigitalJS export -- see [Scripts overview](scripts.md))
- A modern browser to open [digitaljs.tilk.eu](https://digitaljs.tilk.eu/) (no install; uploads stay client-side)

Optional (FPGA):

- Vivado (for synthesis/implementation, XSim behavioral simulation, and Hardware Manager)

Optional (manual PDF):

- TeX Live with `latexmk`, and `make`

For install commands on Ubuntu 24.04, with or without `sudo`, see [Prerequisites](prerequisites.md).

---

## 1. Start with VHDL modules (unit testbenches)

Unit testbenches are small, self-checking, and fast. They live under `sim/unit/`.

Run a unit testbench:

```sh
./scripts/run_unit_tb.sh regfile
```

Run a unit testbench and dump waves (`--fst` recommended):

```sh
./scripts/run_unit_tb.sh --fst alu
./scripts/view_wave.sh build/waves/tb_alu.fst
```

What to look for in waves:

- Inputs change -> outputs settle (combinational blocks like the ALU)
- Clocked behavior happens on the expected edge (e.g., regfile writes on rising edge; same-cycle W->D read-after-write is handled by a small bypass mux)

---

## 2. Visualize module waveforms with GTKWave

The `--fst` dump above is the fast, compact format; `--vcd` and `--wave` (GHDL's `.ghw`) are
also supported if you prefer. `view_wave.sh` is a thin wrapper around GTKWave:

```sh
./scripts/view_wave.sh build/waves/tb_alu.fst
```

Use this step to build intuition about the signals you will later look for in DigitalJS
(step 3) and in Vivado XSim (step 6).

---

## 3. Explore simple modules interactively with DigitalJS

DigitalJS ([digitaljs.tilk.eu](https://digitaljs.tilk.eu/)) is a browser-based schematic
viewer *and* interactive simulator. You drive inputs by clicking; it propagates values
through the gates. For a leaf module this is often more illuminating than a waveform.

Export a DigitalJS JSON with `gen_schematic.sh`:

```sh
./scripts/gen_schematic.sh --digitaljs alu
./scripts/gen_schematic.sh --digitaljs regfile
./scripts/gen_schematic.sh --digitaljs extend
```

Then upload `build/schematics/<entity>.digitaljs.json` to digitaljs.tilk.eu and toggle the
inputs. Any 1-bit `clk`/`clock` input is exported as a self-ticking `Clock` device; any
other 1-bit input (e.g. `reset`) is exported as a one-click `Button`; multi-bit inputs
are typeable number fields (see [Scripts overview -- clock and reset handling in DigitalJS](scripts.md#clock-and-reset-handling-in-digitaljs)).
For the full flag reference and prerequisites, see
[Scripts overview -- gen_schematic.sh](scripts.md#gen_schematicsh).

This step is a **companion** to step 2, not a replacement: DigitalJS does not check a
signature, and the simulation runs in a browser rather than the GHDL engine. Use it when
you want to *see* what a module does; use GHDL + GTKWave when you need to *verify* it.

---

## 4. Run full-core ISA tests (assembly and C programs)

Integration tests live in `tests/isa/`. Each test writes a signature to DMEM at:

- Signature base address: `0x2000_0100`

Run an existing assembly test:

```sh
./scripts/run_test.sh addi_only
```

Run with per-instruction trace to see how each instruction flows through the
pipeline stages (decoded assembly, control signal selections per stage, and
hazard unit decisions):

```sh
./scripts/run_test.sh --trace addi_only
```

Example trace output (one block per clock cycle):

```
ASM=addi x6, x0, 5
FETCH: PC=0x0000000C INSTR=0x00500313
DECODE [addi x6, x0, 5]: ImmSrc=I
EXEC [addi x5, x5, 256]: SrcA=rs1 ALUSrc=imm ALUControl=add
MEM [lui x5, 0x20000000]:
WB [addi x0, x0, 0]: ResultSrc=alu RegWrite=yes
HAZARD [addi x5, x5, 256]: FwdA=M FwdB=rf
```

Each block is a **pipeline snapshot**: the `[instruction]` annotation on each
line shows exactly which instruction occupies that pipeline stage. Empty/flushed
slots appear as `[---]`. The `HAZARD:` line is annotated with the E-stage
instruction because forwarding decisions are made for the instruction in Execute.
See [Instruction tests -- trace logging](instruction_tests.md#optional-per-instruction-trace-logging)
for a worked example and signal reference.

Run with waves and view in GTKWave:

```sh
./scripts/run_test.sh --fst addi_only
./scripts/view_wave.sh build/waves/addi_only.fst
```

How correctness is checked:

- The DUT stores result words into the signature window in DMEM.
- The testbench compares those words to `tests/isa/<test>.sig`.
- On mismatch, the simulator reports both expected and observed words.

Next: once you're comfortable reading waves + signatures, modify one of the
assembly tests under `tests/isa/*.S` and rerun.

C tests (for example `factorial.c`, `full_core.c`) are driven by the same
`run_test.sh` entry point -- the script detects whether the matching file under
`tests/isa/` is `.S` or `.c` and calls `build_prog.sh` accordingly. C programs are
fully freestanding (no libc, no OS) and must write their final observation words
into the signature window at `0x2000_0100`. See [Instruction tests -- authoring
additional C tests](instruction_tests.md#authoring-additional-c-tests) for the
`_start` stub and signature-capture workflow.

For more detail on the build flow and test catalogue, see:
[Instruction tests](instruction_tests.md).

---

## 5. Step through the full pipeline in DigitalJS (with firmware loaded)

Now that a full-core test passes in GHDL, load the same firmware into an interactive
schematic of `top`, the entity that contains the core together with its instruction
and data memories. `gen_schematic.sh --mem-init` patches the Yosys `$mem`/`$mem_v2`
INIT parameters with the hex images produced by `build_prog.sh`, so the DigitalJS
simulation starts with the real program in IMEM and real initial data in DMEM
(otherwise every cell powers up all-zeros -- see
[Scripts overview -- memory initialization for DigitalJS](scripts.md#memory-initialization-for-digitaljs)).

```sh
./scripts/build_prog.sh tests/isa/full_core.c full_core
./scripts/gen_schematic.sh --digitaljs \
    --mem-init imem_dp=build/full_core.text.hex \
    --mem-init dmem=build/full_core.data.hex \
    top
```

Upload `build/schematics/top.digitaljs.json` to
[digitaljs.tilk.eu](https://digitaljs.tilk.eu/), press the simulator's run button, then
click the `reset` button once to pulse reset: the clock auto-ticks, the PC advances,
the instruction flows through F/D/E/M/W, and the signature writes land in DMEM.  The
exported netlist is pre-wired with a self-ticking `Clock` for `clk` and a one-click
`Button` for `reset` (see [Scripts overview -- clock and reset handling in DigitalJS](scripts.md#clock-and-reset-handling-in-digitaljs)),
so no manual clock toggling is needed.

**Limitations:**

- `--mem-init` only works on the hierarchical (default) netlist, where `imem_dp` and
  `dmem` appear as distinct modules. Under `--flat` they are merged into the top level
  and the injection becomes a no-op (the script prints a warning).
- DigitalJS is slower than GHDL for anything longer than a few hundred cycles; use it
  for *exploration*, not for regression.
- This step does not check a signature. Treat step 4 as the authoritative pass/fail and
  use this step to visualise what is happening inside the pipeline for a chosen region
  of the program.

---

## 6. Move to Vivado (XSim simulation, synthesis, FPGA bring-up)

The Vivado path re-runs the same RTL and the same testbench you already validated under
GHDL, then takes it through synthesis, implementation, and on-chip validation. There are
three sub-steps:

1. **XSim behavioral simulation.** Import `rtl/*.vhd` + `sim/tb_minrv32.vhd` into a Vivado
   project, force VHDL-2008 on the imported sources (Vivado defaults to VHDL-93), point
   the testbench generics at your `build/<name>.text.hex` / `build/<name>.data.hex` and at
   `tests/isa/<name>.sig`, and look for `Note: TEST PASSED`. This is the direct analogue
   of step 4 inside Vivado.
2. **Synthesis + implementation.** Use the same RTL with `fpga_top.vhd` as the design top
   (a thin synthesis wrapper around `top.vhd` that exposes only `clk`, `reset`, and a
   1-bit activity `led` so the FPGA pad ring stays minimal; the `led` is the MSB of a
   free-running blink counter XORed with an XOR reduction of every observation signal, so
   it blinks while the clock runs and synthesis does not prune the datapath). `fpga_top` also
   makes the core clock (by default 80 MHz on Basys3 and ZedBoard) from the
   100 MHz board clock. The hex files
   are passed in through top-level generics; Vivado reads them during synthesis and
   stores the program in the block RAM contents of the bitstream.
3. **On-board bring-up.** Program the board, then validate using an ILA that
   captures the signature words as the core writes them to DMEM.

Follow: [Vivado instructions](vivado_instructions.md).

### Evaluate using signature + ILA capture

On FPGA, you validate a program using the same signature idea used in
simulation, but observing the store bus with an Integrated Logic Analyzer
(ILA) as the core writes the signature window:

1. Build the program and keep `tests/isa/<test>.sig` as the expected output
   (for a new test, generate it with Spike: `./scripts/gen_golden.sh --words N --write <test>`;
   see [Golden signatures with Spike](instruction_tests.md#golden-signatures-with-spike)).
2. Insert an ILA on the `MARK_DEBUG`'d nets in `top.vhd` (`dmem_addr_i`,
   `dmem_wdata_i`, `dmem_write_en_i`, `dmem_wstrb_i`, `pc`, `instr`).
3. Trigger on a store into the signature window (`dmem_write_en_i == 1` and
   `dmem_addr_i == 32'h2000_01??`).
4. Run the design on the board and let the ILA capture fire.
5. Extract the captured `dmem_wdata_i` words in address order and compare
   against `tests/isa/<test>.sig`.

The signature starts at byte address `0x2000_0100`; each word index `i`
corresponds to address `0x2000_0100 + 4*i`.

The concrete Tcl commands (trigger setup, `run_hw_ila`, `write_hw_ila_data`)
are in: [Vivado instructions](vivado_instructions.md#8-validate-a-program-via-the-signature-window-ila-capture).

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
