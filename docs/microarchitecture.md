# Pipelined Microarchitecture

## Overview

This repository implements a five-stage RV32I pipeline (F/D/E/M/W) based on the Harris & Harris reference design. Instructions overlap in flight; explicit pipeline registers separate stages and a hazard unit adds forwarding, stall, and flush control. Instruction and data memories use synchronous reads (BRAM-style), and their output registers serve as the F->D and M->W pipeline registers for `InstrD` and `ReadDataW` respectively -- no separate explicit registers are needed for those two signals.

The design is intentionally modular. A pipelined `controller_pipe` + `datapath_pipe` split keeps decode/control separate from datapath math. `datapath_pipe` itself is a **structural** architecture that instantiates five stage wrappers (`fetch_stage`, `decode_stage`, `execute_stage`, `memory_stage`, `writeback_stage`), each containing named entity instances for pipeline registers (`pipe_reg`), muxes, and functional units. This hierarchy gives Vivado's elaborated design view a navigable per-stage breakdown, while dedicated VHDL entities isolate register storage, ALU logic, branch comparison, memory alignment, and load extension.

## Block diagrams

These schematics are generated straight from the RTL with Yosys + netlistsvg via
[`scripts/gen_schematic.sh`](../scripts/gen_schematic.sh) (default *hierarchical*
mode, so every sub-module instance is a labelled box). They show the design at
four zoom levels, from the system boundary down to the Execute-stage internals.
Open an image and zoom for the port-level wiring; the committed PDF renders used
by the [manual](../latex/manual/main.pdf)
live in [`latex/common/figures/`](../latex/common/figures/) (`uarch_*.pdf`).

To regenerate, e.g. `./scripts/gen_schematic.sh -o build/schematics riscvpipe`.

### System (`top`)

The synthesis top wires the pipelined core (`rvpipe_inst`) to the dual-port
instruction memory (`imem_dp_inst`) and the data memory (`dmem_inst`).

![netlistsvg block schematic of top: core plus instruction and data memories](../latex/common/figures/uarch_system.svg)

### Core (`riscvpipe`)

`riscvpipe` binds the controller (`ctrl_inst`), the structural datapath
(`datapath_inst`), and the hazard unit (`hazard_inst`).

![netlistsvg block schematic of riscvpipe: controller, datapath, and hazard unit](../latex/common/figures/uarch_core.svg)

### Datapath stages (`datapath_pipe`)

`datapath_pipe` is purely structural: it instantiates the five per-stage
wrappers (`fetch_inst`, `decode_inst`, `execute_inst`, `memory_inst`,
`writeback_inst`) and wires the inter-stage signals between them.

![netlistsvg block schematic of datapath_pipe: the five pipeline stage wrappers](../latex/common/figures/uarch_stages.svg)

### Execute-stage internals (`execute_stage`)

Drilling into one stage shows the named functional units: the ALU (`alu_inst`),
the branch unit (`branch_inst`), the forwarding and operand-select muxes
(`mux_a_fwd`/`mux_b_fwd`, `mux_a_sel`/`mux_b_sel`), the D->E pipeline registers
(`de_*_reg`), and the branch-target adder.

![netlistsvg block schematic of execute_stage internals: ALU, branch unit, forwarding and operand muxes, D-to-E registers](../latex/common/figures/uarch_execute.svg)

## Module Map

### High-level flow

The blocks below map directly to RTL entities and stage registers:

- **Fetch (F)** - `PCF` register and next-PC mux select between `PC+4` and taken branch/jump targets (`PCSrcE`, `JalrE`). The instruction memory (`imem_dp`, port A) reads the instruction at `PCF`; its registered output appears one cycle later as `InstrD`.
- **Decode (D)** - `InstrD` comes from the IMEM BRAM output register (masked to NOP by `flush_d_hold` when a pipeline flush was requested on the previous cycle). `PCD`/`PCPlus4D` are explicit pipeline registers. `controller_pipe` decodes opcode/funct fields, `extend` produces `ImmExtD`, and the `regfile` reads RS1/RS2.
- **Execute (E)** - `RD1E/RD2E/ImmExtE/PCE` pipeline registers feed the ALU and branch unit. Forwarding muxes select between `RDxE`, `ALUResultM`, and `ResultW`. Branch compare produces `ZeroE`.
- **Memory (M)** - `ALUResultM` holds the effective address. `mem_access_unit` aligns the store payload and generates byte strobes for SB/SH/SW before driving the DMEM interface.
- **Writeback (W)** - `ReadDataW` comes from the DMEM BRAM output register (no explicit capture needed); the WB mux selects between ALU, memory, or `PCPlus4W` and writes the regfile on the rising edge (with a combinational bypass mux to resolve same-cycle W->D read-after-write).

### `riscvpipe`, `top`, and `fpga_top`
`riscvpipe.vhd` binds `controller_pipe`, `datapath_pipe`, and `hazard_unit` into the pipelined core. `top.vhd` wires the core to a dual-port instruction memory (`imem_dp`) and a data memory (`dmem`), and exposes textbook top-level ports (`clk`, `reset`, `WriteData`, `DataAdr`, `MemWrite`, `MemRead`, `MemWStrb`) so the VHDL testbench can observe memory traffic directly. `fpga_top.vhd` is a thin synthesis wrapper around `top` that exposes `clk`, `reset`, and a single 1-bit `led` activity indicator (driven by the MSB of a free-running blink counter XORed with an XOR reduction of every observation signal from `top`: the counter makes the LED blink visibly while the clock runs, and the XOR fold prevents synthesis from removing the datapath as dead code). It also makes the core clock from the board clock with an MMCM (the FPGA's clock generator block; by default 80 MHz on Basys3 and ZedBoard, see [Vivado instructions](vivado_instructions.md#changing-the-core-clock)). It is the Vivado synthesis top and keeps the FPGA pad ring at 3 IOs while leaving the observation nets accessible via ILA + `MARK_DEBUG`.

> **Important (outside `riscvpipe`, implemented in `top`):** A registered mux in
> `top` routes data-side loads that target addresses below `DMEM_BASE_ADDR` to
> the second read port of `imem_dp`. This enables `.rodata` constants placed in
> the text region to be accessed by load instructions. The mechanism is
> essential for the software/hardware interface: the linker script places
> `.rodata` alongside `.text` in IMEM, and the dual-port read path makes those
> constants available to the core's load instructions without duplicating
> memory. See [Memory map](memory_map.md) for the address layout.

### `controller_pipe`
`controller_pipe.vhd` performs decode in D and registers control into E/M/W. It emits:

- `ImmSrcD` for immediate decoding.
- E-stage controls (`ALUControlE`, `SrcASelE`, `ALUSrcBE`, `BranchOpE`, `JumpE/JalrE`, `PCSrcE`).
- M/W stage controls for memory access and write-back (`MemWriteM`, `MemReadM`, `MemSizeM`, `MemUnsignedM`, `RegWriteM`, `RegWriteW`, `ResultSrcW`, `MemSizeW`, `MemUnsignedW`).

`StallD` freezes the D->E control register and `FlushE` inserts a bubble on hazards or taken branches.

### `datapath_pipe`
`datapath_pipe.vhd` is a **structural** architecture that instantiates five stage wrappers and wires the inter-stage signals between them. It contains no processes or inline logic; every functional element lives inside a named sub-entity, producing a clear per-stage hierarchy in Vivado's elaborated design:

- **`fetch_stage`** (`fetch_inst`): PC register (`pipe_reg`), PC+4 adder, next-PC muxes (`mux2` instances: `pc_branch_or_jalr_mux`, `pc_next_mux`), and BRAM read-enable generation.
- **`decode_stage`** (`decode_inst`): F->D `pipe_reg` instances (`fd_pc_reg`, `fd_pc_plus4_reg`), `flush_d_hold` process (NOP insertion mux), `regfile`, and `extend`.
- **`execute_stage`** (`execute_inst`): D->E `pipe_reg` instances (8 registers), forwarding `mux3` instances, ALU-B `mux2`, `alu`, `branch_unit`, and branch/jump target computation.
- **`memory_stage`** (`memory_inst`): E->M `pipe_reg` instances (4 registers) and `mem_access_unit`.
- **`writeback_stage`** (`writeback_inst`): M->W `pipe_reg` instances (3 registers), `load_extend_unit`, and WB result `mux3`.

A reusable **`pipe_reg`** entity (generic `WIDTH`, ports for `clk/rst/flush/stall/d/q`) implements all explicit pipeline registers. `InstrD` and `ReadDataW` remain sourced from the BRAM output registers as described below, so they do not have corresponding `pipe_reg` instances.

### `hazard_unit`
`hazard_unit.vhd` resolves the three hazard classes of a 5-stage pipeline:
data hazards (forwarding + load-use stall), control hazards (flush on taken
branch/jump), and -- in the stall-only mode -- generic RAW stalls. The
`FORWARDING_ENABLE` generic selects, at elaboration time, one of two
mutually exclusive bodies via `if ... generate`. The stall/flush *outputs*
(`StallF`, `StallD`, `FlushD`, `FlushE`) are computed by shared logic that is
identical in both modes; only the internal stall condition (`stallD_i`) and
the forwarding muxes differ.

The explanations below describe *why each condition exists*, not just what it
computes.

#### Forwarding-enabled mode (`FORWARDING_ENABLE=true`)

**Operand forwarding (`ForwardAE`, `ForwardBE`).** Each ALU operand mux picks
its source for the instruction in E:

| Select | Source | Asserted when |
| ------ | ------ | ------------- |
| `"00"` | register file (`RDxE`) | no hazard, or source is `x0` (default) |
| `"10"` | `ALUResultM` (from M) | `RsxE = RdM` and `RegWriteM='1'` and `MemReadM='0'` and `RsxE /= x0` |
| `"01"` | `ResultW` (from W)    | `RsxE = RdW` and `RegWriteW='1'` and `RsxE /= x0` |

- **M before W priority.** If the same register is in flight in both M and W,
  the copy in M is the *newer* write (it entered the pipeline later), so it
  must win. The `if/elsif` order encodes this.
- **`MemReadM='0'` on the M path.** A load in M does not have its data yet --
  `ALUResultM` still holds the computed *address*. Forwarding it would inject
  the address in place of the loaded value. Loads are instead handled by the
  load-use stall below; one cycle later the value reaches W and is forwarded
  safely from there (W-stage data is always the final committed value, so the
  W path needs no such guard).
- **`RsxE /= x0`.** `x0` is hardwired to zero and is never a real dependency,
  so it must not trigger forwarding.

**Load-use stall (`stallD_i`).** A load in E (`ResultSrcEb0='1'`) produces its
result only at the *end* of M -- too late to forward into the dependent
instruction that is already in E during that same cycle. The fix is to stall F
and D for one cycle and flush E (bubble), after which the load reaches W and
its value forwards normally. The condition is:

```
stallD_i = ResultSrcEb0='1'
           and ( (Rs1D=RdE and Rs1D/=x0) or (Rs2D=RdE and Rs2D/=x0) )
```

The `/=x0` guards prevent a false stall when the consumer reads `x0`.

#### Stall-only mode (`FORWARDING_ENABLE=false`)

`ForwardAE/ForwardBE` are tied to `"00"` (the ALU always reads the register
file), so every RAW dependency must be resolved by stalling until the producer
writes back in W. `stallD_i` is the OR of the same load-use term *and* a
generic RAW term:

```
rawStallD_b = (Rs1D=RdE or Rs2D=RdE) and RegWriteE='1' and RdE/=x0
           or (Rs1D=RdM or Rs2D=RdM) and RegWriteM='1' and RdM/=x0
           or (Rs1D=RdW or Rs2D=RdW) and RegWriteW='1' and RdW/=x0
```

- **`RegWriteE/M/W='1'`.** Stores (S-type) and branches (B-type) reuse the `Rd`
  bit-field for immediate bits, so a non-zero `Rd` does *not* imply a register
  write. Gating on the actual `RegWrite` control avoids stalling on
  dependencies that do not exist.
- **`Rdx /= x0`.** A "write to `x0`" is discarded by the ISA, so an instruction
  whose destination is `x0` (e.g. `BEQ`, which encodes `Rd=0`) is not a
  producer and must not cause a stall.

#### Shared stall/flush outputs (both modes)

```
StallF = stallD_i and not PCSrcE
StallD = stallD_i and not PCSrcE
FlushD = PCSrcE
FlushE = stallD_i or PCSrcE
```

- **`StallF` / `StallD`** freeze the PC and the F/D register so the dependent
  instruction stays in D until the hazard clears.
- **`FlushD = PCSrcE`** kills the instruction in D when a branch/jump resolves
  taken in E: that instruction was fetched speculatively from the fall-through
  path and must become a bubble.
- **`FlushE`** inserts a bubble into E for *either* reason: (1) a data stall has
  frozen D, so the instruction already in E must not be re-executed; or (2) a
  taken branch, whose wrong-path successor in E must be squashed.
- **`and not PCSrcE` on the stalls.** When a taken branch coincides with a data
  stall, the PC must still redirect to the target. `StallF` is the *only* gate
  on the PC update (there is no flush on the PC), so without this term the PC
  would freeze and the core would re-fetch the wrong-path instruction forever
  -- hence the guard is **required on `StallF`**. On `StallD` it is
  **redundant**: `FlushD=PCSrcE` already clears the F/D register, and `pipe_reg`
  prioritises flush over stall (`rst/flush > stall > load`), so the F/D register
  becomes a bubble regardless of `StallD`. It is kept on `StallD` only for
  symmetry. Note also that in forwarding mode `stallD_i` (load in E) and
  `PCSrcE` (taken branch/jump in E) are mutually exclusive -- the same E-stage
  instruction cannot be both -- so the guard only ever *fires* in stall-only
  mode, where a `JAL`/`JALR` both writes `rd` and sets `PCSrcE`.

### Memory helpers (`mem_access_unit`, `load_extend_unit`)
`mem_access_unit.vhd` computes byte strobes and aligned store data for SB/SH/SW, and returns a raw load word for later extension. `load_extend_unit.vhd` applies byte/half/word sign/zero extension in the writeback stage using `MemSizeW/MemUnsignedW`.

### `regfile`
`regfile.vhd` is a 2R/1W register file with rising-edge writeback and a combinational write-forwarding (bypass) mux at each read port. This resolves same-cycle W->D read-after-write without requiring a falling-edge write, keeping all sequential logic on a single clock edge for BRAM inference and timing closure (see [Textbook differences](textbook_differences.md) for rationale).

## Core Operation (Pipeline)

1. **Fetch (F)** - `PCF` selects `PC+4` or the E-stage target. `InstrF` is read from instruction memory (`imem_dp`, port A).
2. **Decode (D)** - `InstrD`/`PCD` are registered. The controller decodes control signals and the regfile reads RS1/RS2. `ImmExtD` is produced.
3. **Execute (E)** - Forwarding selects the correct operands. The ALU computes results and `branch_unit` evaluates the branch. `PCSrcE` decides the next PC and triggers `FlushD` when taken.
4. **Memory (M)** - Address and store data are registered; stores are issued with byte strobes. Load data is captured into `ReadDataW`.
5. **Writeback (W)** - The WB mux selects ALU, memory, or `PCPlus4W` and writes the regfile on the rising edge.

Stalls and flushes preserve correctness when dependencies or control hazards occur.

## Extending or Integrating the Core

- **New instructions** typically update `maindec/aludec` plus the pipeline control registers in `controller_pipe`.
- **Alternative memories** can replace `imem`/`dmem` as long as they honor the same interfaces. Synchronous BRAM wrappers require treating memory outputs as pipeline registers and adjusting timing.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
