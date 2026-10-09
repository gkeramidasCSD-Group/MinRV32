# RTL module map (quick navigation)

This folder contains the synthesizable VHDL for an educational 5-stage RV32I
pipeline (F/D/E/M/W). Most modules are intentionally "textbook shaped".

If you want the longer-form explanation, start from [docs/microarchitecture.md](../docs/microarchitecture.md)
and [docs/pipeline_migration.md](../docs/pipeline_migration.md).

## Dependency-order reading sequence

Read in this order to avoid encountering unknown types or enums.

**1. Packages**
- `core_pkg.vhd` - all shared types, enums, and constants used everywhere
- `mem_init_pkg.vhd` - simulation-only memory initialisation helpers

**2. Leaf primitives** (no internal instantiations)
- `mux2.vhd`, `mux3.vhd`, `pipe_reg.vhd`
- `extend.vhd`, `regfile.vhd`
- `alu.vhd`, `aludec.vhd`, `maindec.vhd`
- `branch_unit.vhd`, `load_extend_unit.vhd`, `mem_access_unit.vhd`
- `hazard_unit.vhd`
- `imem_dp.vhd`, `dmem.vhd`

**3. Mid-level** (instantiate leaves)
- `controller_pipe.vhd` <- `maindec`, `aludec`
- `fetch_stage.vhd` <- `mux2/3`, `pipe_reg`
- `decode_stage.vhd` <- `pipe_reg`, `regfile`, `extend`
- `execute_stage.vhd` <- `pipe_reg`, `mux2/3`, `alu`, `branch_unit`
- `memory_stage.vhd` <- `pipe_reg`, `mem_access_unit`
- `writeback_stage.vhd` <- `pipe_reg`, `mux2/3`, `load_extend_unit`

**4. Top-level structural**
- `datapath_pipe.vhd` <- all five pipeline stage wrappers
- `riscvpipe.vhd` <- `controller_pipe`, `datapath_pipe`, `hazard_unit`
- `top.vhd` <- `riscvpipe`, `imem_dp`, `dmem`
- `fpga_top.vhd` <- `top` (FPGA synthesis wrapper, hides debug ports)

## Top-level structure

- `fpga_top.vhd` - Thin FPGA synthesis wrapper around `top`. Exposes only
  `clk`, `reset`, and a 1-bit `led` activity indicator. The observation
  ports (`DataAdr`, `WriteData`, `MemWrite`, `MemRead`, `MemWStrb`) from
  `top` are captured internally and XOR-reduced into `led` so that (a)
  synthesis cannot prune the datapath as dead code and (b) the board shows
  a visible sign of life while the core runs. It also makes the core clock
  from the board clock with an MMCM (the FPGA's clock generator block; by
  default 80 MHz on Basys3 and ZedBoard) and holds the core in reset until that clock is stable. This
  is the Vivado synthesis
  top; internal nets remain observable on-board via an Integrated Logic
  Analyzer (ILA) -- the relevant nets in `top.vhd` already carry
  `MARK_DEBUG=true`.
- `top.vhd` - Synthesizable top wrapper: instantiates the core + instruction/data
  memories and implements the IMEM-vs-DMEM read mux for `.rodata` loads.
  Used directly as the design-under-test in simulation (via `sim/top_trace.vhd`).
- `riscvpipe.vhd` - Structural core wrapper: binds `controller_pipe`,
  `datapath_pipe`, and `hazard_unit`.

## Control / datapath / hazards

- `controller_pipe.vhd` - Decode + pipelined control registers (D->E->M->W); builds
  control words using `maindec` + `aludec`.
- `datapath_pipe.vhd` - **Structural** top-level datapath: instantiates the five
  stage wrappers below and wires inter-stage signals. Contains no processes or
  inline logic of its own.
- `hazard_unit.vhd` - RAW hazard handling (forwarding, load-use stall, flush)
  with a `FORWARDING_ENABLE` generic to switch between "forwarding" and
  "stall-only" modes.

## Pipeline stage wrappers

Each stage is a self-contained entity with named sub-component instances,
giving Vivado's elaborated design view a navigable per-stage hierarchy.

- `pipe_reg.vhd` - Generic N-bit pipeline register with rst/flush/stall control.
  Instantiated by name in each stage (e.g. `fd_pc_reg`, `de_rd1_reg`).
- `fetch_stage.vhd` - PC register (`pipe_reg`), PC+4 adder, next-PC muxes, and
  BRAM read-enable generation.
- `decode_stage.vhd` - F->D pipeline registers, NOP insertion (`flush_d_hold`),
  `regfile`, and `extend`.
- `execute_stage.vhd` - D->E pipeline registers, forwarding mux3 instances,
  ALU-B mux, `alu`, `branch_unit`, and branch/jump target computation.
- `memory_stage.vhd` - E->M pipeline registers and `mem_access_unit`.
- `writeback_stage.vhd` - M->W pipeline registers, `load_extend_unit`, and WB
  result mux.

## Functional blocks

- `regfile.vhd` - RV32 register file (2R/1W) with x0 hardwired to zero and a
  same-cycle write-forwarding bypass (rising-edge write).
- `alu.vhd` - Combinational ALU for RV32I arithmetic/logic + shifts.
- `branch_unit.vhd` - Combinational branch comparator (signed/unsigned).
- `extend.vhd` - Immediate extraction + sign/zero extension for RV32I formats.
- `mem_access_unit.vhd` - Store-data alignment + byte strobe generation for
  SB/SH/SW.
- `load_extend_unit.vhd` - Combinational load-data sign/zero extension
  (byte/half/word) applied in the writeback stage.

## Decode helpers

- `maindec.vhd` - Main opcode/funct3 decoder (high-level control + mem data size MEM_BYTE/HALF/WORD).
- `aludec.vhd` - ALU control decoder (ALUOp + funct3/funct7).

## Memory models (BRAM-friendly)

- `imem_dp.vhd` - True dual-port synchronous-read ROM (fetch + text-region
  read for `.rodata` loads).
- `dmem.vhd` - Synchronous-read RAM with byte-write enables + optional hex init.

## Small building blocks

- `mux2.vhd` - Generic 2:1 mux.
- `mux3.vhd` - Generic 3:1 mux with a simulation-only guard on illegal selects.
- `core_pkg.vhd` - Shared types/enums/constants + small helper functions.
- `mem_init_pkg.vhd` - Shared simulation-only hex loader used by `imem_dp`/`dmem`.
  Kept in `rtl/` because both memory models `use work.mem_init_pkg.all` at
  compile time - moving it to `sim/` would require it to compile into the same
  `work` library across a folder boundary, or force a separate library name into
  the RTL use clauses. The `synthesis translate_off` guards mean synthesis tools
  see only a zero-initialized memory; only the simulator ever runs the file I/O.
