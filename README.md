# Pipelined RV32I Core (Educational)

An educational 5-stage pipelined RV32I CPU in VHDL, designed as a hands-on learning platform for:

- **VHDL digital design** -- read, modify, and simulate synthesizable RTL at the module and system level.
- **RISC-V computer architecture (RV32I)** -- understand how a pipelined processor fetches, decodes, executes, accesses memory, and writes back results, including hazard handling (forwarding, stalls, flushes).
- **The hardware/software interface** -- write freestanding C programs that run directly on the core, explore how the compiler, linker script, and memory map interact with the hardware.
- **FPGA implementation** -- synthesize the design in AMD Xilinx Vivado, program a board, and validate results by capturing the signature window with an on-chip ILA over JTAG.

The project is not tied to a specific FPGA device; any board supported by Vivado can be targeted by supplying the appropriate constraints file.

> [!NOTE]
> **FPGA results in MinRV32 publications.** Papers and reports about MinRV32 describe the repository as it was when they were written. The RTL, clocking, scripts, and constraints keep evolving, so the FPGA implementation results in a publication (resource usage, power estimate, timing slack, maximum frequency, and critical path) can differ from what the current version of the repository produces. Results also depend on the Vivado version, the target device, and the ILA configuration. Most differences come from ordinary updates; some come from fixes. In particular, the results in the BCI conference paper were obtained with an earlier version whose timing constraint did not match the clock the core actually received; this was fixed by generating the core clock with an MMCM. See [Notes on published results](docs/vivado_instructions.md#notes-on-published-results) for what changed, and [Resources and power](docs/vivado_instructions.md#resources-and-power) for the results of the current version.

**What you can reproduce in this repo**

- **Component bring-up with unit testbenches** (`sim/unit/`) and optional wave dumps (`--fst`) for GTKWave.
- **Full-core ISA + C regression tests** (`tests/isa/`) that self-check via a memory-mapped **signature window** (`.sig` files).
- **Waveform-first debugging**: dump `.fst`/`.vcd`/`.ghw` from the same tests you use for correctness.
- **Vivado FPGA flow** with **on-chip ILA capture** of the signature window (JTAG, triggered on stores to `0x2000_0100`) to validate results on hardware.

When instructions reference the repository root, they use the placeholder `<repo_root>`.

## Software prerequisites

Required (simulation + building test programs):

- GHDL (VHDL-2008)
- RISC-V bare-metal toolchain (`riscv64-unknown-elf-gcc`, `riscv64-unknown-elf-objcopy`)
- Python 3

Optional:

- GTKWave (waveform viewer for `.fst`/`.vcd`/`.ghw`)
- Yosys + yosys-plugin-ghdl + Graphviz + netlistsvg + yosys2digitaljs (SVG schematic generation)
- Vivado (FPGA implementation + Hardware Manager)
- Spike RISC-V ISA simulator (generates the golden `.sig` files; built from source, see [Prerequisites](docs/prerequisites.md#24-spike))
- TeX Live with `latexmk`, and `make` (rebuilding the LaTeX manual)

For install commands on Ubuntu 24.04, with or without `sudo`, see [Prerequisites](docs/prerequisites.md).

## Quick tour (the educational route)

1. **Simulate VHDL modules + view waves**

   ```sh
   ./scripts/run_unit_tb.sh --fst alu
   ./scripts/view_wave.sh build/waves/tb_alu.fst    # opens GTKWave
   ```

   Waveform dumps use the FST format by default (compact and fast). Pass `--vcd`
   or `--wave` for alternative formats. GTKWave is used to inspect the resulting
   waveforms -- see [Prerequisites](docs/prerequisites.md) for
   installation instructions.

2. **Run an assembly ISA test (correctness via `.sig`, per-instruction trace + waves)**

   ```sh
   ./scripts/run_test.sh --trace addi_only
   ./scripts/run_test.sh --fst addi_only
   ./scripts/view_wave.sh build/waves/addi_only.fst
   ```

   The `--trace` flag prints a per-instruction trace showing the decoded
   assembly, control signal selections at each pipeline stage, and hazard unit
   decisions. Combine it with `--fst` to get both console trace and waveforms.

3. **Run a freestanding C test (correctness via `.sig`, per-instruction trace + waves)**

   ```sh
   ./scripts/run_test.sh --trace factorial
   ./scripts/run_test.sh --fst factorial
   ./scripts/view_wave.sh build/waves/factorial.fst
   ```

4. **Generate golden signatures with Spike (new or changed tests)**

   ```sh
   ./scripts/gen_golden.sh --check factorial            # Spike vs tests/isa/factorial.sig
   ./scripts/gen_golden.sh --words 4 --write my_test    # create tests/isa/my_test.sig
   ./scripts/check_goldens.sh                           # check every .sig file
   ```

   Spike runs the same program and reads the signature window at `0x2000_0100`.
   Code is linked at `0x8000_0000` for Spike, so do not store raw code addresses
   in the signature (see [code-address differences](docs/instruction_tests.md#golden-signatures-with-spike-code-address-differences)).

5. **Implement on FPGA + validate via ILA capture**

   In Vivado Hardware Manager, insert an ILA on the `MARK_DEBUG`'d nets in
   `top.vhd` and trigger on stores to the signature window (see the full guide
   in [Vivado instructions](docs/vivado_instructions.md)):

   ```tcl
   # Signature base = 0x2000_0100, DMEM base = 0x2000_0000.
   # Trigger: dmem_write_en_i == 1 AND dmem_addr_i == 32'h2000_01??
   set ila [lindex [get_hw_ilas] 0]
   run_hw_ila  $ila
   wait_on_hw_ila $ila
   write_hw_ila_data -csv_file signature_capture.csv [upload_hw_ila_data $ila]
   ```

Start-to-finish walkthrough: [Learning path](docs/learning_path.md).

## Scope (RV32I subset)

The core targets a small "GCC-friendly" RV32I subset that can run useful freestanding C:

- Control flow: `JAL`, `JALR`, `BEQ/BNE/BLT/BGE/BLTU/BGEU`
- Address/materialization: `LUI`, `AUIPC`
- Loads/stores: `LB/LBU/LH/LHU/LW`, `SB/SH/SW`
- Integer ALU: OP-IMM + OP (`ADD/SUB/AND/OR/XOR/SLT/SLTU/SLL/SRL/SRA`, plus immediate forms)

Omitted (by design): `FENCE*`, CSR/system instructions, `ECALL/EBREAK`.

## Reference textbook

This implementation is inspired by the pipelined processor presented in:
*Digital Design and Computer Architecture, RISC-V Edition* (Sarah Harris, David Harris, Morgan Kaufmann, 2021).

Signal naming and the overall pipeline structure follow the textbook where possible, but this design diverges in several areas (synchronous BRAM memories, structural datapath hierarchy, full branch set, byte/half load/store support, rising-edge regfile with bypass, and others). See [Textbook differences](docs/textbook_differences.md) for a complete list.

## Documentation at a glance

Start here:

- [Prerequisites](docs/prerequisites.md) - install the tools on Ubuntu 24.04, with or without `sudo`.
- [Learning path](docs/learning_path.md) - step-by-step educational flow (VHDL sim -> waves -> asm/C tests -> FPGA + ILA signature capture).

Architecture (how it works):

- [Microarchitecture overview](docs/microarchitecture.md)
- [Instruction control signals](docs/instruction_control.md)
- [Memory map](docs/memory_map.md)
- [Textbook differences](docs/textbook_differences.md)
- [Pipeline design decisions](docs/pipeline_migration.md)

Simulation + tests (how you validate it):

- [Instruction tests](docs/instruction_tests.md)
- [Scripts overview](docs/scripts.md)
- [Manual testing](docs/manual_testing.md) - run every test by hand and check the results that open in a window (waveforms, schematics, DigitalJS, Vivado). `scripts/health_check.sh` runs the terminal tests automatically.

FPGA (how you run it on hardware):

- [Vivado instructions](docs/vivado_instructions.md)

Long-form write-up (LaTeX, build with `make` in the latex directory):

- [Project manual (PDF)](latex/manual/main.pdf) - the full technical manual covering microarchitecture, ISA/control, memory and toolchain, tests, and the Vivado/FPGA flow ([source](latex/manual/)).
