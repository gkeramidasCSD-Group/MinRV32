# Differences vs Textbook Pipelined (Harris & Harris)

This document summarizes how this repository differs from the Harris & Harris
pipelined reference design.

## ISA coverage

- **Full RV32I branch set.** The core supports all RV32I branch types
  (BEQ/BNE/BLT/BGE/BLTU/BGEU), while the textbook often highlights a smaller
  subset in diagrams.
- **Load/store sizing.** Byte/half/word loads and stores are fully supported
  with sign/zero extension; the reference example uses simpler word-only RAMs.

## Control + datapath organization

- **Pipelined controller.** Control is generated in D (`controller_pipe.vhd`)
  and registered into E/M/W. Signal naming is stage-suffixed (`ImmSrcD`,
  `ALUControlE`, `MemWriteM`, `ResultSrcW`) rather than using only unsuffixed
  wires.
- **Structural datapath hierarchy.** `datapath_pipe.vhd` uses a structural
  architecture that instantiates five per-stage wrapper entities
  (`fetch_stage`, `decode_stage`, `execute_stage`, `memory_stage`,
  `writeback_stage`). Each wrapper contains named `pipe_reg` instances and
  functional-unit instantiations, producing a navigable hierarchy in Vivado's
  elaborated design view. The textbook keeps the datapath as a single
  flat module.
- **Branch comparator.** A dedicated `branch_unit` handles all branch types,
  instead of relying solely on ALU `Zero`.
- **ALU A selection.** The datapath supports `SrcASelE` (RS1/PC/zero) rather
  than a single implicit PC/RS1 path. The `OPA_ZERO` selection exists
  specifically for `LUI`: the instruction semantics are `rd = imm << 12`, which
  the ALU computes as `0 + ImmExt` (the immediate is already left-shifted by
  the `extend` unit). Using a dedicated zero input avoids routing the LUI
  through the `x0` register read, keeping the datapath mux simple and explicit
  (see the LUI row in [Instruction control](instruction_control.md)).

## Datapath details

- **BRAM-sourced pipeline signals.** `InstrD` and `ReadDataW` are sourced from
  BRAM output registers (the instruction and data memory outputs respectively),
  not from explicit flip-flops. Because synchronous BRAMs latch their output on
  the clock edge, the BRAM output register inherently acts as the pipeline
  register for that stage boundary -- no separate flip-flop is needed for
  `InstrD` (F->D) or `ReadDataW` (M->W). See the "Memories and interfaces"
  section below for full details.
- **Load extension in W.** `load_extend_unit.vhd` applies sign/zero extension
  in W using the registered `ReadDataW` and `MemSizeW/MemUnsignedW`. The
  textbook inlines this logic in the datapath.
- **Mem access helper.** `mem_access_unit.vhd` centralizes byte strobes and
  store data alignment instead of inline datapath logic.

## Hazards

- **Forwarding + stalls.** A dedicated `hazard_unit.vhd` implements forwarding,
  load-use stalls, and flush control. M-stage forwarding is suppressed for
  loads, matching the data-availability timing.
- **Hazard unit design choices.** The forwarding and stall logic tracks the
  textbook structure but adds guards needed for this RTL's timing:
  - **M-stage forwarding excludes loads.** Loads only have valid data in W, so
    `MemReadM='1'` disables M-stage forwarding to prevent using stale values.
    W-stage forwarding is always safe because the final value is available.
  - **RAW stall checks are gated by RegWrite.** Some instruction encodings
    (stores/branches) carry a non-zero `Rd` field even though they do not write
    a register; `RegWriteE/M/W='1'` avoids false stalls on those cases.
  - **Control-flow redirect overrides data stalls.** When `PCSrcE='1'` (taken
    branch/jump), the pipeline must advance to the target even if a data stall
    is asserted; otherwise the core can re-fetch the wrong-path instruction and
    fail to make progress.

## Memories and interfaces

- **Synchronous BRAM reads (synthesis-ready).** `imem_dp` and `dmem` use
  clocked (synchronous) reads instead of the textbook's combinational reads.
  Because a synchronous BRAM latches its output on the clock edge, that
  internal output register serves the same role as an explicit pipeline
  register at the stage boundary -- no separate flip-flop is needed:

  | Textbook (combinational)           | This design (synchronous BRAM)                   |
  |------------------------------------|--------------------------------------------------|
  | `InstrF` available same cycle      | BRAM latches `InstrD` on next rising edge         |
  | Explicit `InstrD` flip-flop in F-->D | BRAM output register *is* the F-->D latch           |
  | Explicit `ReadDataW` flip-flop     | DMEM output register *is* the M-->W latch           |
  | No memory enable needed            | `imem_en` deasserted during Decode-stage stalls   |

  **Why deviate?** Combinational-read arrays cannot map to FPGA Block RAM
  primitives. Vivado (and Intel Quartus) require the read inside a
  `rising_edge(clk)` process with an enable guard to infer BRAM. Making this
  change in the memory models keeps the core synthesizable on real hardware
  while preserving identical pipeline timing and hazard behaviour.

  **Does this add a pipeline stage?** No. Instead of adding a 6th stage, the
  synchronous-memory output registers *become* the stage-boundary latches:

  - **Instruction fetch timing (IMEM):** during cycle N, `PCF` is presented to
    instruction memory. On the next rising edge (cycle N+1), the BRAM output
    register updates and the instruction is available as `InstrD` for Decode.
    In other words, Fetch "issues the read" and Decode "consumes the registered
    output".
  - **Load timing (DMEM):** during cycle N, the load address in `ALUResultM` is
    presented to data memory. On the next rising edge (cycle N+1), the BRAM
    output register updates and the load word is available as `ReadDataW` for
    Writeback.

  The stage names (F/D/E/M/W) describe when values are valid and consumed, not
  when a BRAM address is presented.

- **`flush_d_hold` replaces explicit NOP insertion.** The textbook resets
  `InstrD` to a NOP inside the F-->D pipeline register process. Because the
  BRAM output cannot be overridden synchronously, a one-bit `flush_d_hold`
  register captures the flush request and a combinational mux inserts the NOP
  one cycle later -- the same logical effect, implemented around the BRAM.

- **DMEM byte-write pattern.** Stores use direct byte-lane signal assignments
  (`if wstrb(i)='1' then mem(addr)(slice) <= data(slice)`) instead of a
  read-modify-write variable. This matches the Xilinx UG901 template for
  BRAM byte-write-enable inference.

- **Explicit read enable.** `dmem` includes a `MemRead` enable so loads are
  explicitly qualified; the textbook memory is read-always.
- **`imem_en` port.** The instruction memory receives a clock-enable driven
  by the datapath (`'1' when not reset and not stalled`). On a stall the
  enable is low, so the BRAM holds its last output -- equivalent to freezing
  the `InstrD` register.
- **Harvard split exposed via `top`.** Instruction and data ports are separate
  in `top.vhd`, while the core itself remains textbook-compatible in signal
  naming.

- **True dual-port instruction memory (`imem_dp`).**  The design needs two
  simultaneous read accesses to instruction memory: one for instruction fetch
  (driven by the PC) and one for data-side loads that target the text region
  (e.g., `.rodata` constants placed below `DMEM_BASE_ADDR`).

  A naive approach instantiates the single-port `imem` twice with identical
  init files, but synthesis treats them as two independent memories, doubling
  BRAM utilization. Instead, `imem_dp.vhd` exposes two read ports (A and B)
  backed by a single shared `mem` array inside one clocked process -- the
  standard Vivado UG901 / Quartus template for true dual-port BRAM inference
  (RAMB36E1 TDP mode on Xilinx 7-series).

  | Configuration                        | BRAM primitives (1024 words) |
  |--------------------------------------|------------------------------|
  | Two separate `imem` instances        | 2x RAMB36E1                  |
  | One `imem_dp` dual-port instance     | 1x RAMB36E1                  |

  **Scaling (IMEM + DMEM).** On Xilinx 7-series devices at 32-bit word width,
  a `RAMB36E1` stores ~1024 words, so BRAM usage scales roughly as
  `WORDS / 1024` per memory:

  - With the default sizing (`IMEM_WORDS=2048`, `DMEM_WORDS=2048`), `imem_dp`
    is ~2x `RAMB36E1` and `dmem` is ~2x `RAMB36E1`.
  - Duplicating instruction memory (two separate `imem` instances) would
    double the IMEM cost (e.g., ~4x `RAMB36E1` for `IMEM_WORDS=2048`).

  **Why deviate?**  Halving instruction-memory BRAM usage matters on smaller
  FPGAs (e.g., Artix-7 XC7A35T) and scales linearly with program size. Since
  instruction memory is read-only at runtime, there are no read-during-write
  ordering concerns -- the behaviour is bit-identical in both simulation and
  synthesis.

## Register file

- **Rising-edge write with bypass (diverges from textbook).**  The textbook
  (Harris & Harris, Fig. 7.47) writes the register file on the **falling**
  clock edge so that a same-cycle read in the Decode stage naturally sees the
  freshly written value by the time the next rising edge latches the D->E
  pipeline register.

  This implementation writes on the **rising** edge instead and adds a
  combinational write-forwarding (bypass) mux at each read port:

  ```
  rs1_data <= rd_data   when (wr_en AND rs1_addr = rd_addr AND rd /= x0)
              else       regs(rs1_addr);
  ```

  **Why deviate?**

  1. **BRAM inference.**  Xilinx and Intel FPGA Block RAM primitives only
     support single-edge clocking. A `falling_edge(clk)` write prevents the
     synthesis tool from mapping the register file into BRAM, forcing it into
     distributed flip-flops (32 x 32 = 1024 FFs on Xilinx). Rising-edge
     writes are compatible with the BRAM inference templates documented in
     Vivado UG901.

  2. **Timing closure.**  A falling-edge write path must settle within half a
     clock period. At higher target frequencies this half-cycle constraint can
     become a bottleneck. Rising-edge writes use the full clock period.

  3. **STA simplicity.**  Multi-edge designs complicate static timing analysis
     and introduce additional clock-domain considerations in the timing reports.
     Keeping all sequential elements on the same (rising) edge simplifies
     constraint files and timing closure.

  The bypass mux adds a 2:1 multiplexer on each read-data output, which is
  negligible in area and timing compared to the register array itself. The
  forwarding logic in the hazard unit is unaffected -- it still handles E/M/W
  stage data hazards; the regfile bypass only resolves the W->D same-cycle
  read-after-write case.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
