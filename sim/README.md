# Simulation module map (quick navigation)

This folder contains simulation-only VHDL wrappers and testbenches. These files
are compiled for GHDL/XSim but are not intended for synthesis.

If you want the higher-level story (pipeline stages, hazards, and BRAM timing),
start from [docs/microarchitecture.md](../docs/microarchitecture.md) and [docs/textbook_differences.md](../docs/textbook_differences.md).

## Full-core testbench (self-checking)

- `tb_minrv32.vhd` - Integration testbench used by `scripts/run_test.sh`:
  - Preloads instruction/data memories from `*.text.hex` / `*.data.hex` images.
  - Detects completion by monitoring a DMEM signature window and comparing
    against a `.sig` file.
  - Prints an optional per-instruction stage trace when `TRACE_ENABLE=true`
    (use `./scripts/run_test.sh --trace <name>`).
  - Treats missing input files as warnings by default; set `STRICT_FILES=true`
    to fail fast.

## Trace wrappers (simulation only)

These wrappers keep the synthesizable RTL unchanged while exposing internal
signals that are useful for teaching, waveform exploration, and trace printing.

- `top_trace.vhd` - Simulation-only alternative top level:
  - Instantiates the traced core (`riscvpipe_trace`) plus `imem_dp` (dual-port
    IMEM) and `dmem` models, matching `rtl/top.vhd`.
  - Exposes extra debug ports (PC/instruction and grouped control/hazard
    selections) consumed by the testbench trace printer.
  - Mirrors the `.rodata` load behavior from `rtl/top.vhd` by serving reads
    below `DMEM_BASE_ADDR` from instruction memory.
- `riscvpipe_trace.vhd` - Simulation-only wrapper around the pipelined core:
  - Instantiates `controller_pipe`, `datapath_pipe`, and `hazard_unit`.
  - Adds "dbg" output ports for the control selections and hazard decisions so
    the testbench can print a stage-grouped trace (FETCH/DECODE/EXEC/MEM/WB).

**Maintenance note:** The trace wrappers duplicate the structural wiring of
their RTL counterparts (`rtl/top.vhd` and `rtl/riscvpipe.vhd`). When ports or
sub-module interfaces change in the RTL, the corresponding trace wrapper must
be updated to match. This duplication is a deliberate trade-off: it keeps the
synthesizable RTL free of simulation-only ports and conditionals, at the cost
of requiring parallel maintenance. VHDL-2008 external names (`<<signal ...>>`)
could eliminate the duplication but are not yet portable across all target
simulators.

## Unit testbenches (component bring-up)

Under `unit/` you'll find small, assert-based testbenches for individual RTL
blocks:

- `unit/tb_alu.vhd` - ALU opcode coverage.
- `unit/tb_hazard_unit.vhd` - forwarding and stall/flush behavior.
- `unit/tb_mem_access_unit.vhd` - byte strobes and store alignment.
- `unit/tb_regfile.vhd` - x0 behavior and same-cycle bypass.

## Running

Use the scripts in `scripts/`:

- `./scripts/run_unit_tb.sh alu` - run a unit testbench (add `--fst/--vcd/--wave`).
- `./scripts/run_test.sh addi_only` - run an ISA test (add `--trace` to print the text trace).

For full script documentation (environment overrides, waveform options, batch
regression, etc.), see [docs/scripts.md](../docs/scripts.md).
