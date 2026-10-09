# Manual testing

This page shows how to test the whole repository by hand, one command at a
time, and what each result must look like. It has two parts:

- [Part 1](#part-1-terminal-checks) runs commands whose result is text in the
  terminal. `scripts/health_check.sh` runs the same commands automatically
  (see [Scripts overview](scripts.md#health_checksh)).
- [Part 2](#part-2-visual-checks) opens results in a window: waveforms,
  schematics, the DigitalJS web simulator, Vivado, and the manual PDF. No
  script can check these for you.

The order follows the [Learning path](learning_path.md). Install the tools
first: see [Prerequisites](prerequisites.md).

The expected values on this page were taken from runs on Ubuntu 24.04 with the
tool versions listed in [Prerequisites, section 6](prerequisites.md#6-what-was-checked-for-this-page).
The windows in Part 2 were not opened when this page was checked; the values
that they must show were read from the same files with command-line tools.

---

## Before you start

Open a terminal in the repository root, the directory that contains
`README.md`. For the Vivado steps, also load Vivado's settings (replace
`<xilinx-dir>` and `<version>` with your installation):

```sh
cd <repo_root>
source <xilinx-dir>/Vivado/<version>/settings64.sh
```

All outputs are written under `build/`. Part 1, step 12 deletes it again.

---

## Part 1: terminal checks

Run the commands in this order. A later step uses files that an earlier step
writes.

| # | Command | The output must contain |
|---|---------|-------------------------|
| 1 | `./scripts/build_prog.sh tests/isa/full_core.c full_core` | A `Sizes:` block, and no line that starts with `error:` |
| 2 | `./scripts/run_unit_tests.sh` | `Results: 4 passed, 0 failed out of 4 testbenches.` |
| 3 | `./scripts/run_tests.sh` | `Results: 8 passed, 0 failed out of 8 tests.` |
| 4 | `./scripts/run_test.sh full_core` | `TEST PASSED` and `simulation stopped @28335ns with status 0` |
| 5 | `./scripts/run_test.sh --trace addi_only` | One block per clock cycle with `ASM=`, `FETCH:`, `DECODE`, `EXEC`, `MEM`, and `WB` lines (example below) |
| 6 | `FORWARDING_ENABLE=false ./scripts/run_tests.sh` | `Results: 8 passed, 0 failed out of 8 tests.` (the core uses stalls instead of forwarding) |
| 7 | `./scripts/check_goldens.sh` | `Results: 8 match, 0 differ out of 8 golden files.` |
| 8 | `./scripts/gen_schematic.sh --all` | `Done: 24 generated, 0 failed.` (one schematic per entity in `rtl/`) |
| 9 | `./scripts/gen_schematic.sh --digitaljs alu` | `Done: 1 generated, 0 failed.` |
| 10 | `./scripts/gen_schematic.sh --digitaljs --mem-init imem_dp=build/full_core.text.hex --mem-init dmem=build/full_core.data.hex top` | A line `[INIT] imem_dp...: 169 word(s) loaded`, four `[INIT] dmem...` lines, and `Done: 1 generated, 0 failed.` |
| 11 | `make -C latex pdf` | `Output written on main.pdf (46 pages ...)` |
| 12 | `./scripts/clean.sh` | `Removed <repo_root>/build` |

Notes:

- Step 4 runs one C test on its own, to show its pass time: 28335 ns. Part 2,
  step 6 expects the same time in Vivado.
- Step 11 rewrites `latex/manual/main.pdf`, which is stored in git. Run
  `git checkout latex/manual/main.pdf` afterwards if you do not want to keep
  the new file.
- Run step 12 only after Part 2, because Part 2 opens files in `build/`.

The first cycles of step 5 look like this (`[---]` is an empty pipeline slot):

```
ASM=lui x5, 0x20000000
FETCH: PC=0x00000004 INSTR=0x200002B7
DECODE [lui x5, 0x20000000]: ImmSrc=U
EXEC [addi x0, x0, 0]: SrcA=rs1 ALUSrc=imm ALUControl=add
MEM [---]:
WB [---]: ResultSrc=alu
```

---

## Part 2: visual checks

### 1. ALU waveform in GTKWave

```sh
./scripts/run_unit_tb.sh --fst alu
./scripts/view_wave.sh build/waves/tb_alu.fst
```

GTKWave opens. In the tree at the top left, click `tb_alu`. Select the
signals `op`, `a`, `b`, and `result` in the list below it and click
**Append**. Each test vector lasts 1 ns. GTKWave shows `op` by its name; if
your GTKWave shows a number instead, 0 is `ALU_ADD`, 1 is `ALU_SUB`, and so on
in the order of the table. The first vectors must show:

| Time | `op` | `a` | `b` | `result` |
|------|------|-----|-----|----------|
| 1 ns | `ALU_ADD` | `00000001` | `00000002` | `00000003` |
| 2 ns | `ALU_SUB` | `00000003` | `00000001` | `00000002` |
| 3 ns | `ALU_AND` | `0F0F0F0F` | `00FF00FF` | `000F000F` |
| 4 ns | `ALU_OR`  | `0F0F0F0F` | `00FF00FF` | `0FFF0FFF` |
| 5 ns | `ALU_XOR` | `0F0F0F0F` | `00FF00FF` | `0FF00FF0` |
| 6 ns | `ALU_SLT` | `FFFFFFFF` | `00000001` | `00000001` |
| 7 ns | `ALU_SLTU`| `00000001` | `FFFFFFFF` | `00000001` |
| 8 ns | `ALU_SLL` | `00000001` | `0000001F` | `80000000` |
| 9 ns | `ALU_SRL` | `80000000` | `0000001F` | `00000001` |

### 2. Full-core waveform in GTKWave

```sh
./scripts/run_test.sh --fst addi_only
./scripts/view_wave.sh build/waves/addi_only.fst
```

In the tree, click `tb_minrv32` and append `clk`, `rst`, `pc_dbg`,
`mem_write`, `data_adr`, and `write_data`. The clock period is 10 ns. You must
see:

- `rst` is `1` until 50 ns, then `0`.
- `pc_dbg` is `00000004` at the rising edge at 65 ns and grows by 4 at each
  following edge while the program runs through its straight-line code.
- `mem_write` is `1` at the rising clock edges listed below. At each of
  these edges `data_adr` and `write_data` have the values below, which are
  the six words of `tests/isa/addi_only.sig`:

| Rising edge | `data_adr` | `write_data` |
|-------------|------------|--------------|
| 125 ns | `20000100` | `00000002` |
| 155 ns | `20000104` | `00000001` |
| 185 ns | `20000108` | `00000800` |
| 215 ns | `2000010C` | `FFFFF7FF` |
| 245 ns | `20000110` | `00000000` |
| 265 ns | `20000114` | `FFFFFF85` |

The simulation stops at 275 ns, when the testbench reports `TEST PASSED`.

### 3. Schematics

After Part 1, step 8, open the SVG files in a web browser or an image viewer:

```sh
xdg-open build/schematics/top.svg
xdg-open build/schematics/fpga_top.svg
```

- `top.svg` must show three boxes: `rvpipe_inst` (the core), `imem_dp_inst`
  (instruction memory), and `dmem_inst` (data memory), connected by the
  `dmem_*` nets.
- `fpga_top.svg` must show `core_inst` (an instance of `top`), the clock
  generator `mmcm_inst`, and the two clock buffers `clk_bufg` and `fb_bufg`.
  Yosys does not know the inside of the Xilinx clock blocks, so they are
  empty boxes.

### 4. DigitalJS

After Part 1, steps 9 and 10, open https://digitaljs.tilk.eu/ in a web
browser and upload a file.

- `build/schematics/alu.digitaljs.json`: the ALU with typeable number fields
  for its inputs. Enter the values of a row of the table in step 1 and check
  `result`.
- `build/schematics/top.digitaljs.json`: the core with its memories. The file
  contains a `Clock` named `clk`, a `Button` named `reset`, and the three
  sub-circuits `rvpipe_inst`, `imem_dp_inst`, and `dmem_inst`. Start the
  simulation, click `reset` once, and check that the program counter
  advances. [Learning path, step 5](learning_path.md#5-step-through-the-full-pipeline-in-digitaljs-with-firmware-loaded)
  explains this view.

### 5. Manual PDF

After Part 1, step 11, open `latex/manual/main.pdf`. It must have 46 pages,
and the table of contents must have no `??` marks (a `??` is a broken
cross-reference).

### 6. Vivado simulation (XSim)

```sh
./scripts/build_prog.sh tests/isa/full_core.c full_core
vivado -source scripts/vivado_project.tcl -tclargs full_core basys3
```

Vivado opens with the project. In the Tcl Console at the bottom, run:

```tcl
launch_simulation
```

The simulation runs until the testbench stops it. The Tcl Console must show
`Note: TEST PASSED` at 28335 ns, the same time as Part 1, step 4. In the
waveform window, add the testbench signals `pc_dbg`, `mem_write`,
`data_adr`, and `write_data` (from the `tb_minrv32` scope). The last ten
stores must be the ten words of `tests/isa/full_core.sig`:

| Rising edge | `data_adr` | `write_data` |
|-------------|------------|--------------|
| 28205 ns | `20000100` | `00004A78` |
| 28215 ns | `20000104` | `ECA8643F` |
| 28255 ns | `20000108` | `C77FC03F` |
| 28265 ns | `2000010C` | `0000018E` |
| 28275 ns | `20000110` | `0002018E` |
| 28285 ns | `20000114` | `0001827E` |
| 28295 ns | `20000118` | `C7028A47` |
| 28305 ns | `2000011C` | `000001CB` |
| 28315 ns | `20000120` | `FD23373A` |
| 28325 ns | `20000124` | `6CF9B359` |

(These times were read from the GHDL waveform of the same testbench; XSim
reports the same pass time.)

### 7. Vivado implementation and timing

In the same Vivado window, run in the Tcl Console:

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
open_run impl_1
report_timing_summary
```

This takes several minutes. In the report, check:

- **WNS** (worst negative slack, the time margin of the slowest path) is `0`
  or more. A negative WNS means that the core clock is too fast; see
  [Vivado instructions -- changing the core clock](vivado_instructions.md#changing-the-core-clock).
- The clock `mmcm_out` (the core clock made by the MMCM) has a period of
  12.500 ns (80 MHz). Repeat steps 6 and 7 with `zedboard` in place of
  `basys3`; its default core clock is also 80 MHz (see the board table in
  [Vivado instructions](vivado_instructions.md#2-create-the-vivado-project-one-command)).
- The file `build/vivado/full_core/minrv32_full_core.runs/impl_1/fpga_top.bit`
  exists.

### 8. On a board

This needs a Basys3 or ZedBoard connected over USB. Follow
[Vivado instructions](vivado_instructions.md) sections 5 (insert the ILA),
6 (bitstream), 7 (program the board), and 8 (capture the signature). The ten
captured `dmem_wdata_i` values must be the ten words of
`tests/isa/full_core.sig`, in the order of the table in step 6. The LED
blinks while the core clock runs. This step was not checked for this page.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
