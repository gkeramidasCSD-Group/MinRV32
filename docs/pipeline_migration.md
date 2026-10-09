# Pipeline Design Decisions

This document records the key design decisions in the five-stage pipelined core.
All items below are implemented in the current RTL and follow the Harris & Harris
reference where applicable.

Scope:

- Five-stage pipeline (F/D/E/M/W).
- Full hazard handling (forwarding + stall + flush).
- Synchronous memories suitable for BRAM init from hex files.

## 1) Top-level structure and naming

- Rename signals to stage-suffixed textbook names: `PCF/InstrF`, `opD/funct3D`,
  `ALUControlE`, `MemWriteM`, `ResultSrcW`, `RegWriteW`, etc.
- Update entity names/ports so the pipeline stage signals are explicit.
- Align control naming with the textbook:
  `ImmSrcD`, `SrcASelE`, `ALUSrcBE`, `ResultSrcEb0`, `PCSrcE`, `ZeroE`.

## 2) Pipeline registers

Add explicit pipeline registers between stages:

- **F->D**: `PCD`, `PCPlus4D` (explicit regs with `StallD/FlushD` support) plus `InstrD` (sourced from the synchronous IMEM BRAM output register and masked by `flush_d_hold`; see section 6).
- **D->E**: `PCE`, `RD1E`, `RD2E`, `ImmExtE`, `Rs1E`, `Rs2E`, `RdE`,
  (optionally `PCPlus4E`).
- **E->M**: `ALUResultM`, `WriteDataM`, `RdM`, (optionally `PCPlus4M`).
- **M->W**: `ALUResultW`, `RdW`, `PCPlus4W` (explicit regs) plus `ReadDataW` (sourced from the synchronous DMEM BRAM output register; see section 6).

## 3) Pipelined controller

Split decode and control into pipeline stage signals:

- Decode (D stage): `RegWriteD`, `ResultSrcD`, `MemWriteD`, `MemReadD`, `JumpD`,
  `JalrD`, `BranchD`, `ALUOpD`, `ImmSrcD`, `ALUControlD`, `SrcASelD`,
  `ALUSrcBD`, `BranchOpD`, `MemSizeD`, `MemUnsignedD`.
- D->E control reg: `RegWriteE`, `ResultSrcE`, `MemWriteE`, `MemReadE`, `JumpE`,
  `JalrE`, `BranchE`, `ALUControlE`, `SrcASelE`, `ALUSrcBE`, `BranchOpE`,
  `MemSizeE`, `MemUnsignedE`.
- E->M control reg: `RegWriteM`, `ResultSrcM`, `MemWriteM`, `MemReadM`,
  `MemSizeM`, `MemUnsignedM`.
- M->W control reg: `RegWriteW`, `ResultSrcW`, `MemSizeW`, `MemUnsignedW`.
- Compute `PCSrcE = (BranchE and ZeroE) or JumpE`.

## 4) Hazard unit

Implement a dedicated hazard unit with:

- **Forwarding**: `ForwardAE`, `ForwardBE` based on `Rs1E/Rs2E` vs `RdM/RdW`
  with `RegWriteM/RegWriteW`.
- **Load-use stall**: detect when a load in E is needed by D (use
  `ResultSrcEb0`, `Rs1D`, `Rs2D`, `RdE`) and assert `StallF`, `StallD`, `FlushE`.
- **Control hazard flush**: assert `FlushD` on taken branch/jump and
  `FlushE` when required by mispredict or stall policy.

## 5) Datapath changes

- Add ALU input muxes for forwarding paths.
- Support `SrcASelE`/`ALUSrcBE` style selection (for PC-relative and LUI flows).
- Move branch compare to E stage (`ZeroE`) and use stage control.
- Update write-back mux to use `ResultSrcW`.

## 6) Memory system (BRAM-style synchronous reads)

- `imem`/`dmem` use synchronous reads (registered output on `rising_edge(clk)`),
  matching the FPGA Block RAM inference pattern. The BRAM output registers serve
  as pipeline registers: IMEM output = `InstrD` (F->D), DMEM output =
  `ReadDataW` (M->W). No extra explicit registers are needed for those signals.
- `imem` receives `clk` and `en` ports. The datapath drives `imem_en` low during
  Decode-stage stalls so the output holds the current instruction.
- A `flush_d_hold` register in the datapath captures `FlushD` and muxes NOP over
  the BRAM output on the following cycle, replacing the old `InstrD <= NOP_INSTR`
  reset/flush branch in the F->D register process.
- **Diagram note (common confusion):** Because `InstrD` and `ReadDataW` are
  *already registered* inside the synchronous BRAM models, pipeline diagrams can
  make these signals look like they "bypass" the IF/ID or MEM/WB pipeline
  registers. That is intentional in this design: the BRAM output register *is*
  the stage boundary latch for those signals, while only the remaining stage
  state is carried in explicit flip-flops (`PCD/PCPlus4D`, `ALUResultW/RdW/PCPlus4W`, etc.).
- `dmem` writes use direct byte-lane assignments (`if wstrb(i)='1' then
  mem(addr)(slice) <= data(slice)`) for proper Xilinx BRAM byte-write-enable
  inference (UG901).
- Use memory init from `.text.hex`/`.data.hex` via the `init_mem` impure function.
  The same function runs in simulation and in Vivado synthesis; no `INIT_FILE`
  attribute is used.

## 7) Write-back

- Register `ResultSrcW` and `RegWriteW` and drive the regfile from W stage.
- Ensure `RdW` and `ResultW` are aligned with the writeback cycle.
- Use a rising-edge write for the register file with combinational bypass muxes
  at each read port to resolve same-cycle W->D read-after-write, keeping all
  sequential logic on a single clock edge (see [Textbook differences](textbook_differences.md)).

## 8) Testbench updates

- Update the testbench to instantiate the pipelined top.
- If trace remains, rename signals to stage-based names (F/D/E/M/W).
- Update the trace to reflect stalls/flushes and forwarded paths.

## 9) Documentation updates

- [Microarchitecture](microarchitecture.md): pipeline stage description and hazard handling overview.
- [Instruction control](instruction_control.md): control tables with D/E/M/W stage-suffixed signals.
- [Textbook differences](textbook_differences.md): deviations from the Harris & Harris pipelined reference design.
- [Vivado instructions](vivado_instructions.md): BRAM targets require synchronous read wrappers (1-cycle latency) and pipeline alignment changes.

## 10) Structural datapath decomposition

Refactor `datapath_pipe.vhd` from a monolithic `rtl` architecture (with inline
processes, functions, and signal assignments) into a **structural** architecture
that instantiates five per-stage wrapper entities:

- `fetch_stage.vhd` - PC register, PC+4 adder, next-PC muxes, BRAM enable.
- `decode_stage.vhd` - F->D pipeline registers, NOP insertion, regfile, extend.
- `execute_stage.vhd` - D->E pipeline registers, forwarding muxes, ALU, branch
  unit, target computation.
- `memory_stage.vhd` - E->M pipeline registers, mem_access_unit.
- `writeback_stage.vhd` - M->W pipeline registers, load_extend_unit, WB mux.

Supporting new entities:

- `pipe_reg.vhd` - Generic N-bit pipeline register with rst/flush/stall;
  replaces the ad-hoc register processes that were previously inlined in the
  datapath.
- `load_extend_unit.vhd` - Combinational load-data sign/zero extension,
  extracted from the former inline `load_extend` function.

**Why:** Only entity instantiation creates navigable hierarchy in Vivado's
elaborated design / schematic view. VHDL `block` statements and `if true
generate` constructs do *not* produce separate hierarchy levels -- they are
either optimised away or flattened. With each pipeline stage as a named entity
instance (e.g. `fetch_inst : fetch_stage`, `decode_inst : decode_stage`), each
stage appears as a collapsible sub-block in the Vivado schematic, and every
`pipe_reg` and functional-unit instance is individually identifiable.

The `datapath_pipe` entity port list is unchanged, so `riscvpipe.vhd`,
`riscvpipe_trace.vhd`, and `top.vhd` require no modifications.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
