# Instruction Execution and Control Signals

This document explains how each supported RV32I instruction group executes in
the pipelined core and which control signals are required at each stage. The
controller emits decode-stage signals that are registered into E/M/W control
pipelines, matching the Harris & Harris pipelined reference.

## RV32I instruction formats (implemented subset)

The RV32I ISA uses six instruction formats. Each format defines how the 32-bit
instruction word is partitioned into fields:

```
R-type:  [   funct7   | rs2  |  rs1  | funct3 |    rd     | opcode ]
          31       25  24  20  19  15  14    12  11      7   6     0

I-type:  [     imm[11:0]     |  rs1  | funct3 |    rd     | opcode ]
          31               20  19  15  14    12  11      7   6     0

S-type:  [ imm[11:5]  | rs2  |  rs1  | funct3 | imm[4:0]  | opcode ]
          31       25  24  20  19  15  14    12  11      7   6     0

B-type:  [imm[12|10:5]| rs2  |  rs1  | funct3 |imm[4:1|11]| opcode ]
          31       25  24  20  19  15  14    12  11      7   6     0

U-type:  [             imm[31:12]             |    rd     | opcode ]
          31                                 12  11      7   6     0

J-type:  [       imm[20|10:1|11|19:12]       |    rd     | opcode ]
          31                                 12  11      7   6     0
```

Instructions implemented by this core and their formats:

| Format | Instructions |
|--------|-------------|
| R-type | ADD, SUB, AND, OR, XOR, SLT, SLTU, SLL, SRL, SRA |
| I-type | ADDI, ANDI, ORI, XORI, SLTI, SLTIU, SLLI, SRLI, SRAI, LB, LBU, LH, LHU, LW, JALR |
| S-type | SB, SH, SW |
| B-type | BEQ, BNE, BLT, BGE, BLTU, BGEU |
| U-type | LUI, AUIPC |
| J-type | JAL |

Official reference for the RV32I base integer instruction set:
https://docs.riscv.org/reference/isa/unpriv/rv32.html

## Control signal glossary

Signals are grouped by the pipeline stage where they are consumed (suffix
indicates the stage: D = Decode, E = Execute, M = Memory, W = Writeback).

**Decode (D):**

- `ImmSrcD` -- immediate format: `IMM_I/S/B/U/J`

**Execute (E):**

- `SrcASelE` -- selects ALU A input: `OPA_RS1`, `OPA_PC`, `OPA_ZERO`
- `ALUSrcBE` -- selects ALU B input: RS2 vs immediate
- `ALUControlE` -- ALU operation enum (`ALU_ADD`, `ALU_SUB`, etc.)
- `BranchOpE` -- branch comparator operation (`BR_EQ`, `BR_LT`, etc.)
- `JumpE` / `JalrE` -- forces PC redirect; `JalrE` selects RS1+imm target
- `PCSrcE` -- selects `PCNext` from `PCPlus4` vs branch/jump target

**Memory (M):**

- `MemWriteM` / `MemReadM` -- data memory write/read enables
- `MemSizeM` / `MemUnsignedM` -- load/store width and sign control

**Writeback (W):**

- `ResultSrcW` -- write-back mux select: `WB_ALU`, `WB_MEM`, `WB_PC4`
- `RegWriteW` -- enables register file write-back

### Textbook alignment

The control names follow Harris & Harris where possible, with stage suffixes
to indicate which pipeline register drives each signal.

## Stage behavior (pipeline)

- **Fetch (F)**: `PCF` drives `imem_addr`, `InstrF` is read, `PCPlus4F` computed.
- **Decode (D)**: `InstrD` is registered, `controller_pipe` decodes opcode/funct
  fields, `extend` produces `ImmExtD`, and `regfile` reads RS1/RS2.
- **Execute (E)**: operand muxes use `SrcASelE` + `ALUSrcBE`, ALU runs
  `ALUControlE`, `branch_unit` evaluates `BranchOpE`.
- **Memory (M)**: `mem_access_unit` uses `MemReadM`, `MemWriteM`, `MemSizeM`,
  `MemUnsignedM` to drive DMEM.
- **Write-back (W)**: `ResultSrcW` selects ALU/load/PC+4 for `regfile` write.

`PCSrcE` is computed as `(BranchE and ZeroE) or JumpE` in the controller.
`JalrE` further selects the JALR target when `PCSrcE = 1`.

## Instruction group control requirements

Each group lists which signals matter in each stage. Unlisted signals keep the
controller defaults (`mem_read=no`, `mem_write=no`, `reg_write=no`, etc.).

The subsections below include a short stage-by-stage walkthrough (F/D/E/M/W)
focused on *what happens* in the datapath, followed by the key control settings
that make it happen. Keep in mind one important FPGA-driven detail:

- **IMEM is synchronous** (BRAM-style). Fetch presents `PCF` in cycle N and the
  instruction becomes valid as `InstrD` on the next rising edge (cycle N+1).
- **DMEM is synchronous** (BRAM-style). Loads present the address in M in cycle
  N and the loaded word becomes valid as `ReadDataW` on the next rising edge
  (cycle N+1). This is why load data is considered a W-stage value.

## Compact control matrix

Notation: `funct` means derived from `funct3`/`funct7b5`, `size` derives from
`funct3`, and `-` means the default/unused value. `pc_src` is asserted when
`JumpE=1` or when a branch is taken.

**Execute + write-back**

| Group  | ImmSrcD | SrcASelE | ALUSrcBE | ALUControlE | RegWriteW | ResultSrcW |
| ------ | ------- | -------- | -------- | ----------- | --------- | ---------- |
| LUI    | IMM_U   | OPA_ZERO | imm      | ALU_ADD     | yes       | WB_ALU     |
| AUIPC  | IMM_U   | OPA_PC   | imm      | ALU_ADD     | yes       | WB_ALU     |
| JAL    | IMM_J   | OPA_PC   | imm      | ALU_ADD     | yes       | WB_PC4     |
| JALR   | IMM_I   | OPA_RS1  | imm      | ALU_ADD     | yes       | WB_PC4     |
| Branch | IMM_B   | OPA_RS1  | rs2      | ALU_SUB     | no        | WB_ALU     |
| Load   | IMM_I   | OPA_RS1  | imm      | ALU_ADD     | yes       | WB_MEM     |
| Store  | IMM_S   | OPA_RS1  | imm      | ALU_ADD     | no        | WB_ALU     |
| OP-IMM | IMM_I   | OPA_RS1  | imm      | funct       | yes       | WB_ALU     |
| OP     | IMM_I   | OPA_RS1  | rs2      | funct       | yes       | WB_ALU     |

**Memory + PC control**

| Group  | MemReadM | MemWriteM | MemSizeM | MemUnsignedM | BranchOpE | JumpE | JalrE |
| ------ | -------- | --------- | -------- | ------------ | --------- | ----- | ----- |
| LUI    | 0        | 0         | -        | -            | BR_NONE   | 0     | 0     |
| AUIPC  | 0        | 0         | -        | -            | BR_NONE   | 0     | 0     |
| JAL    | 0        | 0         | -        | -            | BR_NONE   | 1     | 0     |
| JALR   | 0        | 0         | -        | -            | BR_NONE   | 1     | 1     |
| Branch | 0        | 0         | -        | -            | funct     | 0     | 0     |
| Load   | 1        | 0         | size     | funct        | BR_NONE   | 0     | 0     |
| Store  | 0        | 1         | size     | 0            | BR_NONE   | 0     | 0     |
| OP-IMM | 0        | 0         | -        | -            | BR_NONE   | 0     | 0     |
| OP     | 0        | 0         | -        | -            | BR_NONE   | 0     | 0     |

### LUI

- **Fetch (F)**: fetch the LUI instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode U-immediate and destination register (`ImmSrcD=IMM_U`).
- **Execute (E)**: compute result = `0 + ImmExtE` (`SrcASelE=OPA_ZERO`,
  `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`).
- **Memory (M)**: no memory access.
- **Write-back (W)**: write ALU result to `rd` (`ResultSrcW=WB_ALU`,
  `RegWriteW=yes`).

### AUIPC

- **Fetch (F)**: fetch the AUIPC instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode U-immediate and destination register (`ImmSrcD=IMM_U`).
- **Execute (E)**: compute result = `PCE + ImmExtE` (`SrcASelE=OPA_PC`,
  `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`).
- **Memory (M)**: no memory access.
- **Write-back (W)**: write ALU result to `rd` (`ResultSrcW=WB_ALU`,
  `RegWriteW=yes`).

### JAL

- **Fetch (F)**: fetch the JAL instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode J-immediate and destination register (`ImmSrcD=IMM_J`).
- **Execute (E)**: compute jump target = `PCE + ImmExtE` and request a redirect
  (`SrcASelE=OPA_PC`, `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`, `JumpE=1`, so
  `PCSrcE=1`).
- **Memory (M)**: no memory access.
- **Write-back (W)**: write link register `rd = PCPlus4W`
  (`ResultSrcW=WB_PC4`, `RegWriteW=yes`).

### JALR

- **Fetch (F)**: fetch the JALR instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode I-immediate, read base register `rs1` (`ImmSrcD=IMM_I`).
- **Execute (E)**: compute jump target = `(rs1 + ImmExtE) & ~1` and request a
  redirect (`SrcASelE=OPA_RS1`, `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`, `JumpE=1`,
  `JalrE=1`, so `PCSrcE=1`).
- **Memory (M)**: no memory access.
- **Write-back (W)**: write link register `rd = PCPlus4W`
  (`ResultSrcW=WB_PC4`, `RegWriteW=yes`).

### Branches (BEQ/BNE/BLT/BGE/BLTU/BGEU)

- **Fetch (F)**: fetch the branch instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode B-immediate and read `rs1`/`rs2` (`ImmSrcD=IMM_B`).
- **Execute (E)**: compare `rs1` vs `rs2` (`BranchOpE` from `funct3`) and compute
  branch target = `PCE + ImmExtE`. Redirect (`PCSrcE=1`) only when the branch
  condition is true.
- **Memory (M)**: no memory access.
- **Write-back (W)**: no register write.

### Loads (LB/LBU/LH/LHU/LW)

- **Fetch (F)**: fetch the load instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode I-immediate and read base register `rs1`
  (`ImmSrcD=IMM_I`).
- **Execute (E)**: compute effective byte address = `rs1 + ImmExtE`
  (`SrcASelE=OPA_RS1`, `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`).
- **Memory (M)**: present `ALUResultM` to DMEM and assert `MemReadM=1`. The
  access helper handles alignment, and `MemSizeM/MemUnsignedM` derive from
  `funct3`.
- **Write-back (W)**: consume the registered DMEM output (`ReadDataW`), apply
  sign/zero extension, and write `rd` (`ResultSrcW=WB_MEM`, `RegWriteW=yes`).

### Stores (SB/SH/SW)

- **Fetch (F)**: fetch the store instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode S-immediate and read `rs1` (base) and `rs2` (store data)
  (`ImmSrcD=IMM_S`).
- **Execute (E)**: compute effective byte address = `rs1 + ImmExtE`
  (`SrcASelE=OPA_RS1`, `ALUSrcBE=imm`, `ALUControlE=ALU_ADD`).
- **Memory (M)**: align store data and generate byte strobes, then write DMEM
  (`MemWriteM=1`, `MemSizeM` from `funct3`).
- **Write-back (W)**: no register write.

### OP-IMM (ADDI/ANDI/ORI/XORI/SLTI/SLTIU/SLLI/SRLI/SRAI)

- **Fetch (F)**: fetch the OP-IMM instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode I-immediate and read source register `rs1`
  (`ImmSrcD=IMM_I`).
- **Execute (E)**: run the ALU on `rs1` and `ImmExtE`. The specific ALU function
  comes from `funct3` (and `funct7b5` for shifts).
- **Memory (M)**: no memory access.
- **Write-back (W)**: write ALU result to `rd` (`ResultSrcW=WB_ALU`,
  `RegWriteW=yes`).

### OP (ADD/SUB/AND/OR/XOR/SLT/SLTU/SLL/SRL/SRA)

- **Fetch (F)**: fetch the OP instruction, compute `PCPlus4F` (common).
- **Decode (D)**: decode R-type fields and read source registers `rs1`/`rs2`.
- **Execute (E)**: run the ALU on `rs1` and `rs2`. The specific ALU function
  comes from `funct3`/`funct7b5`.
- **Memory (M)**: no memory access.
- **Write-back (W)**: write ALU result to `rd` (`ResultSrcW=WB_ALU`,
  `RegWriteW=yes`).

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
