# Vivado Instructions

This guide covers the **Tcl-automated flow** for running MinRV32 inside
Vivado: XSim behavioural simulation, synthesis + implementation, and on-board
validation. A single Tcl script
([`scripts/vivado_project.tcl`](../scripts/vivado_project.tcl)) creates the
project, imports every `rtl/*.vhd` and `sim/*.vhd`, flips all files to
VHDL-2008, wires up the testbench generics, and attaches the right board XDC.
After that you only run Tcl commands like `launch_simulation` or
`launch_runs synth_1`.

If you're following the educational progression
(waves -> assembly/C tests -> FPGA validation), see:
[Learning path](learning_path.md).

---

## 0. Prerequisites

**This project targets Linux.** The upstream build flow
(`riscv64-unknown-elf-gcc`, GHDL, Yosys, `yosys-plugin-ghdl`, `netlistsvg`,
`yosys2digitaljs`) is only packaged for Linux distributions, so the
end-to-end flow in this guide -- including Vivado -- assumes a Linux shell.

> **Windows users:** you can run the full flow under **WSL2 Ubuntu**
> (`wsl --install -d Ubuntu`), but Vivado's implementation and Hardware
> Manager are heavy GUI tools that behave more predictably in a **dedicated
> Linux VM or bare-metal install**. If you plan to do synthesis /
> implementation / bitstream generation regularly, a Linux VM (e.g. Ubuntu
> 22.04 LTS in VirtualBox or VMware) is the recommended path. Use WSL only
> for the build + simulation portions of the learning path.

Make sure the `vivado` executable is on your `PATH`. The installer ships a
settings script that sets up `PATH`, `LD_LIBRARY_PATH`, and `XILINX_VIVADO`
for the shell -- source it once per terminal session (or add the line to
`~/.bashrc` / `~/.zshrc`):

```bash
source /tools/Xilinx/Vivado/<version>/settings64.sh
```

Verify with `which vivado`. All `vivado`, `updatemem`, and Hardware Manager
commands in this guide assume this is done.

---

## 1. Build the program hex images

Generate the IMEM/DMEM hex images for the test you want to run. The repo
includes `tests/isa/full_core.c` (with a matching `full_core.sig`) as the
default end-to-end test:

```bash
cd <repo_root>
./scripts/build_prog.sh tests/isa/full_core.c full_core
```

Outputs land under `build/`:

- `build/full_core.text.hex` -> IMEM preload
- `build/full_core.data.hex` -> DMEM preload
- `build/full_core.elf`      -> full ELF
- `tests/isa/full_core.sig`  -> expected signature (already checked in)

The Tcl script below expects these three files (`*.text.hex`, `*.data.hex`,
`*.sig`) and refuses to run if any are missing.

---

## 2. Create the Vivado project (one command)

```bash
# Open project in the GUI, ready to launch sim/synth:
vivado -source scripts/vivado_project.tcl -tclargs full_core basys3

# Non-interactive (batch) creation:
vivado -mode batch -source scripts/vivado_project.tcl -tclargs full_core zedboard
```

The script takes `<test> <board|part> [<xdc>] [--clk-mhz <f>] [--clk-in-mhz <f>]`:

| Argument            | What it does                                                                 |
|---------------------|------------------------------------------------------------------------------|
| `<test>`            | Test name under `tests/isa/` (e.g. `full_core`, `addi_only`).               |
| `<board\|part>`      | `basys3`, `zedboard`, or a raw Xilinx part number (e.g. `xc7a100tcsg324-1`). |
| `<xdc>`             | Optional. Overrides the default board XDC with your own.                    |
| `--clk-mhz <f>`     | Optional. Core clock frequency in MHz (see [Changing the core clock](#changing-the-core-clock)). |
| `--clk-in-mhz <f>`  | Optional. Frequency of the board's clock input in MHz.                       |

Supported boards:

| Argument    | Part              | XDC attached                                              | Board clock | Default core clock |
|-------------|-------------------|-----------------------------------------------------------|-------------|--------------------|
| `basys3`    | `xc7a35tcpg236-1` | [`constraints/basys3.xdc`](../constraints/basys3.xdc)     | 100 MHz     | 80 MHz             |
| `zedboard`  | `xc7z020clg484-1` | [`constraints/zedboard.xdc`](../constraints/zedboard.xdc) | 100 MHz     | 80 MHz             |
| raw part ID | as given          | only if passed as arg #3 (needed for synthesis)           | 100 MHz, or `--clk-in-mhz` | 80 MHz, or `--clk-mhz` |

The project is created under `build/vivado/<test>/minrv32_<test>.xpr`.

**What the script sets up automatically** (so you don't have to do it in the
GUI):

- Adds every `rtl/*.vhd` as a design source, every `sim/*.vhd` as a simulation
  source, and flips all of them to VHDL-2008.
- Synthesis top = `fpga_top` (thin wrapper around `top` that exposes `clk`,
  `reset`, and a 1-bit `led` activity indicator on the pad ring -- the `led`
  is driven by an XOR reduction of every observation signal from `top` so
  that synthesis cannot prune the datapath as dead code. `fpga_top` also
  makes the core clock from the board clock, see
  [Changing the core clock](#changing-the-core-clock). Internal
  observation nets remain accessible on-board via an ILA -- see Sections 5 and 8);
  simulation top = `tb_minrv32` (drives `top` directly through
  `sim/top_trace.vhd`).
- Synthesis generics: `IMEM_WORDS`, `DMEM_WORDS`, absolute paths for
  `IMEM_INIT_FILE` / `DMEM_INIT_FILE` (Vivado reads these files from its own
  run directory, see [BRAM initialization](#bram-initialization)), and the
  clock settings `CLK_IN_PERIOD_PS`, `MMCM_MULT`, `MMCM_DIVCLK`,
  `MMCM_OUT_DIV`.
- Simulation generics: `IMEM_INIT_FILE`, `DMEM_INIT_FILE`, `EXPECTED_FILE`,
  `SIGNATURE_WORDS` (auto-counted from the `.sig` file), `MAX_CYCLES=5000`
  (matches `scripts/run_test.sh`; the testbench default of 2000 is too short
  for `full_core`), `HALT_ON_PASS=true`.
- Simulation run time `all` (property `xsim.simulate.runtime` of `sim_1`): the
  simulation runs until the testbench stops it. Vivado's default is 1000 ns,
  which ends before `full_core` passes (at 28335 ns).
- Attaches the board XDC as a constraint.

### Changing the core clock

The core does not run at the board clock. `fpga_top.vhd` contains an MMCM
(Mixed-Mode Clock Manager, the clock generator block inside 7-series FPGAs)
that makes the core clock from the board clock:

```
core clock = board clock * MMCM_MULT / (MMCM_DIVCLK * MMCM_OUT_DIV)
```

You do not set these numbers by hand. Pass the core clock you want in MHz,
and the script picks the MMCM settings that give the highest frequency that
is not above it:

```bash
vivado -mode batch -source scripts/vivado_project.tcl \
       -tclargs full_core basys3 --clk-mhz 75
```

The script prints the result, for example:

```
INFO: core clock 75.000 MHz (period 13.333 ns): MMCM_MULT=12 MMCM_DIVCLK=1 MMCM_OUT_DIV=16
```

The XDC file constrains only the board clock (`create_clock -period 10.000`
for 100 MHz). Vivado derives the core clock constraint from it and from the
MMCM settings, so the timing report always checks the real core clock. The
default core clock of each board (table above) is close to the highest
frequency at which implementation still meets timing. This was measured with
Vivado 2024.2 and the `full_core` program:

| Board    | Core clock | Worst setup slack (WNS) | Core clock period minus WNS, as a frequency |
|----------|------------|-------------------------|---------------------------------------------|
| Basys3   | 80 MHz     | 0.175 ns                | 81.1 MHz                                    |
| ZedBoard | 80 MHz     | 0.174 ns                | 81.1 MHz                                    |
| ZedBoard | 75 MHz     | 0.333 ns                | 76.9 MHz                                    |

The margin at 80 MHz is small: 0.17 ns is about 1.4% of the 12.5 ns period.
Running the same implementation again gave the same result, but any change
to the RTL, the program, or the Vivado version moves the logic to other
places on the chip, and the slack can become negative. An earlier version of
the RTL missed 80 MHz on ZedBoard by 0.104 ns. If that happens, use
`--clk-mhz 75`, which has twice the margin.

The last row shows a *pessimistic* estimate. Vivado stops improving
placement and routing once every path meets the clock it was given, so an
implementation at 75 MHz reaches only 76.9 MHz, although an implementation at
80 MHz reaches 81.1 MHz. The frequency that a run reports is reached by that
run's placement, so it is safe, but the real limit can be higher. To find the
limit, implement at a clock close to it.

Both boards use the same 7-series logic, so they have the same slowest path.
It starts at the output of the data-memory block RAM, when a loaded value
decides a branch:

1. Data-memory block RAM output (2.45 ns from the clock edge; the RAM's
   optional extra output register, `DO_REG`, which would add a cycle of
   latency, is not used).
2. The mux in `top.vhd` that chooses between instruction-memory and
   data-memory read data, then the load extension and the result mux of the
   Writeback stage.
3. The forwarding mux of the Execute stage, then the branch comparison.
4. `PCSrcE`, which drives the next-PC mux and the PC register, and also
   `FlushD` and `FlushE`. These clear the Fetch/Decode and Decode/Execute
   pipeline registers, so they reach every flip-flop of those registers,
   through each flip-flop's synchronous reset input.

The slowest endpoints are those reset inputs; in the ZedBoard run, the PC
register was only 0.027 ns behind them. The paths have 11 to 19 logic levels,
and more than half of their delay (about 53% on the path to the PC register,
about 64% on the paths to the reset inputs) is wiring between the logic
blocks, which is why the result depends on placement. Which of the two
endpoint groups is the slowest also depends on placement: with an ILA
inserted (see below), the path to the PC register became the slowest one.

### Resources and power

Post-implementation results on ZedBoard (`xc7z020clg484-1`) at 80 MHz,
measured with Vivado 2024.2, the default implementation strategy, and the
`full_core` program. The ILA column is for an ILA on all 134 `MARK_DEBUG`
bits of `top.vhd`, with a depth of 4096 samples and capture control enabled.

| Resource / result             | Available | Without ILA   | With ILA       |
|-------------------------------|-----------|---------------|----------------|
| Slice LUTs                    | 53200     | 1845 (3.47%)  | 3778 (7.10%)   |
| Slice registers (FF)          | 106400    | 1523 (1.43%)  | 4800 (4.51%)   |
| Occupied slices               | 13300     | 875 (6.58%)   | 2053 (15.44%)  |
| F7 muxes                      | 26600     | 261           | 280            |
| Block RAM tiles (RAMB36)      | 140       | 4 (2.86%)     | 19 (13.57%)    |
| DSP slices                    | 220       | 0             | 0              |
| Bonded IOB                    | 200       | 3             | 3              |
| Global clock buffers (BUFG)   | 32        | 2             | 3              |
| MMCM                          | 4         | 1             | 1              |
| WNS / WHS                     |           | +0.174 / +0.156 ns | +0.240 / +0.065 ns |
| Total on-chip power (est.)    |           | 0.261 W       | 0.289 W        |
| Dynamic power (of which MMCM) |           | 0.152 W (0.116 W) | 0.179 W (0.116 W) |
| Device static power           |           | 0.108 W       | 0.110 W        |

The two BUFGs without the ILA drive the core clock and the MMCM feedback; the
ILA adds a third one for the JTAG clock of its debug hub (the ILA itself
samples on the core clock). The power is Vivado's vectorless estimate. Most
of the dynamic power is the MMCM, which is a fixed cost of the clock
generation: the processor itself accounts for about 0.036 W.

Some frequencies need `MMCM_DIVCLK` larger than 1, which makes the MMCM
output less stable (more *jitter*), and Vivado subtracts that from the
timing margin. In the ZedBoard runs, 80 MHz (`MMCM_MULT=12 MMCM_DIVCLK=1
MMCM_OUT_DIV=15`) had a clock uncertainty of 0.069 ns, and 78 MHz
(`MMCM_MULT=39 MMCM_DIVCLK=5 MMCM_OUT_DIV=10`) had 0.160 ns. If a frequency
fails timing, a nearby frequency that the script makes with `MMCM_DIVCLK=1`
may pass.

**Why there is an MMCM.** Earlier versions of the project clocked the core
directly from the 100 MHz board clock, while the XDC files told Vivado that
the clock was 80 MHz (12.5 ns). Vivado therefore checked timing at 80 MHz
only. Re-checked at the real 10 ns, the routed ZedBoard design of that version
missed timing by 2.249 ns at Vivado's *slow corner* (the slowest chips at the
worst temperature and voltage that the timing models cover; the slowest path
took 12.147 ns), but met it by 4.415 ns at the *fast corner* (the slowest
path took 5.316 ns). A real chip on a lab bench is somewhere between the two
corners, so that design most likely ran correctly, but nothing guaranteed it.
With the MMCM, Vivado checks the clock that the core really gets. If you change the RTL,
check the timing summary after implementation (`report_timing_summary`): a
negative WNS (worst negative slack) means the core clock is too fast, and you
should pass a lower `--clk-mhz`. `scripts/health_check.sh` prints an estimate
of the highest core clock that meets timing; as shown above, the estimate is
pessimistic when the core clock is well below the limit.

**Why an MMCM and not a PLL.** Each clock tile of a 7-series FPGA has one
MMCM and one PLL, and either can make 80 MHz from 100 MHz. On ZedBoard, the
same design was implemented with a PLL in place of the MMCM:

| Clock generator    | Internal oscillator | Clock uncertainty | WNS       | Clock generator power | Total power |
|--------------------|---------------------|-------------------|-----------|-----------------------|-------------|
| MMCM, x12 / 15     | 1200 MHz            | 0.069 ns          | +0.174 ns | 0.116 W               | 0.261 W     |
| PLL, x12 / 15      | 1200 MHz            | 0.069 ns          | -0.178 ns | 0.121 W               | 0.266 W     |
| PLL, x8 / 10       | 800 MHz             | 0.082 ns          | +0.050 ns | 0.097 W               | 0.242 W     |

The power depends on the frequency of the internal oscillator, not on the
type of block, and a slower oscillator gives more jitter (a larger clock
uncertainty). The PLL at 1200 MHz missed timing only because the core logic
was placed differently, which shows again how small the margin at 80 MHz is.
A PLL therefore gives no clear gain for this design, and the MMCM is kept:
its settings search in `scripts/vivado_project.tcl` uses the MMCM limits,
and the MMCM can also divide by fractions (steps of 1/8) if the script is
extended to use them.

The core is held in reset until the MMCM output is stable (its `LOCKED`
output is `1`), and while the reset button is pressed.

### Notes on published results

Papers about MinRV32 report the FPGA results of the repository version that
existed when they were written, so they can differ from the
[current results](#resources-and-power).

**BCI conference paper (camera-ready version).** Its FPGA results were
obtained with the earlier version described in
[Why there is an MMCM](#changing-the-core-clock): the core was clocked
directly by the 100 MHz board oscillator, while the timing constraint
specified 80 MHz. Its timing results (WNS +0.112 ns without the ILA and
+0.269 ns with it, "meets timing at 80 MHz") were therefore checked against an
80 MHz clock, not against the 100 MHz clock that the core actually received.
The design still passed the signature check on the board, because a real chip
on a lab bench is faster than Vivado's worst-case timing model, but timing
closure at the real clock was not guaranteed. The current version fixes this
by generating the 80 MHz core clock with an MMCM, and its timing results are
checked at that clock. Compared with the paper:

| Result | BCI paper (earlier version) | Current version | Reason |
|---|---|---|---|
| Core clock | 100 MHz board clock, constrained as 80 MHz | 80 MHz from the MMCM | Clocking fix |
| LUTs / FFs, without ILA | 1842 / 1521 | 1845 / 1523 | Clock and reset logic (about 0.2%) |
| LUTs / FFs, with ILA | 3763 / 4798 | 3778 / 4800 | Same as above |
| Block RAM tiles, without / with ILA | 4 / 19 | 4 / 19 | Unchanged |
| Global clock buffers, without / with ILA | 1 / 2 | 2 / 3 | MMCM feedback buffer |
| Total power, without / with ILA | 0.162 / 0.192 W | 0.261 / 0.289 W | MMCM, about 0.116 W |
| WNS, without / with ILA | +0.112 / +0.269 ns (at the 80 MHz constraint) | +0.174 / +0.240 ns (at the real 80 MHz clock) | Clocking fix and different placement |

The resource and power numbers of the paper are correct for that version;
the power difference is the fixed cost of the MMCM. The critical path is
still the one from the data-memory output, through forwarding and the branch
comparison, to the next-PC selection. Two details of the paper's description
are corrected here. The ALU is not on the path; the carry chains belong to
the branch comparison and the next-PC adder. And the slack difference between
the builds with and without the ILA comes from the different placement of
the two designs, not from run-to-run variation, because Vivado gives the same
result when the same implementation is run again.

---

## 3. Run behavioural simulation (XSim)

In the Vivado Tcl console (or the GUI `Flow Navigator -> Run Simulation`):

```tcl
launch_simulation
```

The simulation runs until the testbench stops it, because the project script
sets the run time to `all`. When the signature window matches
`tests/isa/<test>.sig` the testbench prints:

```
Note: TEST PASSED
```

If the signature never matches before `MAX_CYCLES` (default 5000) the
`timeout_proc` reports the mismatch and stops the run so you can inspect the
waveforms. Increase `MAX_CYCLES` for longer programs by setting it as an
additional simulation generic.

### Optional: per-instruction trace output

The testbench includes simulation-only wrappers
(`sim/top_trace.vhd`, `sim/riscvpipe_trace.vhd`) that print a per-cycle
pipeline snapshot (decoded assembly + key control signals + hazard decisions).
These are added to `sim_1` by the script automatically; set the
`TRACE_ENABLE=true` generic on `sim_1` to turn the prints on.

```tcl
# Append TRACE_ENABLE to whatever generics the project script already set,
# instead of overwriting them:
set cur [get_property generic [get_filesets sim_1]]
set_property generic "$cur TRACE_ENABLE=true" [get_filesets sim_1]
```

Sample line per cycle:

```
ASM=addi x6, x0, 5
FETCH: PC=0x0000000C INSTR=0x00500313
DECODE [addi x6, x0, 5]: ImmSrc=I
EXEC   [addi x5, x5, 256]: SrcA=rs1 ALUSrc=imm ALUControl=add
MEM    [lui x5, 0x20000000]:
WB     [addi x0, x0, 0]: ResultSrc=alu RegWrite=yes
HAZARD [addi x5, x5, 256]: FwdA=M FwdB=rf
```

See [Instruction tests -- trace
logging](instruction_tests.md#understanding-the-trace-annotated-pipeline-snapshot)
for the full signal reference.

---

## 4. Synthesis

```tcl
launch_runs synth_1 -jobs 4
wait_on_run synth_1
```

### BRAM initialization

The memory models rely on a single mechanism that works for both flows:
the `init_mem` impure function reads the hex file with VHDL TEXTIO at
*elaboration time*. GHDL and XSim execute it for simulation; Vivado's
synthesis elaborator runs the same code and bakes the returned array into
the inferred BRAM's `INIT_xx` parameters, so the program is present in
the bitstream without any tool-specific `INIT_FILE` attribute. The Tcl
script passes the hex paths as *absolute* paths on the synthesis generics
so Vivado can open them from the run directory. Confirm BRAM inference
in the **Utilization Report**: arrays should map to `RAMB36E1` /
`RAMB18E1`, not distributed RAM.

### Expected synthesis warnings

- "Upper address bits unused on `addr(31 downto 2)`" -- expected. The memories
  only consume the low `log2(WORDS)` bits; the rest are left for the decoded
  address compare in `top.vhd`.
- "Default block is never used" in `maindec`/`aludec` -- expected. The
  `when others => null` branches are defensive programming for simulation.

---

## 5. (Optional but recommended) Insert the ILA debug core

On-board signature validation (Section 8) requires an Integrated Logic
Analyzer inside the design so Hardware Manager can trigger on stores to
the signature window and capture the data words. The natural place to
insert it is **after `synth_1` finishes and before `impl_1` runs**: the
debug core is stitched into the synthesized netlist, then implementation
places and routes it together with the rest of the design.

Skip this section if you only want to bring the core up and don't need
hardware-side validation -- you can always come back to it later and
re-run implementation.

`rtl/top.vhd` already carries `MARK_DEBUG=true` on the nets you need, so
they survive synthesis optimization and appear in the Debug wizard by
default:

| VHDL net          | Purpose                                   |
|-------------------|-------------------------------------------|
| `pc`              | program counter (context)                 |
| `instr`           | fetched instruction (context)             |
| `dmem_addr_i`     | data-memory address (trigger qualifier)   |
| `dmem_wdata_i`    | data-memory write data (signature value)  |
| `dmem_write_en_i` | data-memory write enable (trigger signal) |
| `dmem_wstrb_i`    | byte-write strobes                        |
| `dmem_read_en_i`  | data-memory read enable                   |

If you want to probe other nets, add the same attribute pattern in the
RTL (`attribute MARK_DEBUG of <sig> : signal is "true";`) or apply it from
an XDC scoped into the `core_inst` hierarchy under `fpga_top`:

```tcl
set_property MARK_DEBUG true [get_nets -hier {*core_inst/<name>[*]}]
```

### Set Up Debug wizard

1. In Vivado's **Flow Navigator**, after `synth_1` finishes, click
   **Open Synthesized Design**.
2. **Tools -> Set Up Debug** opens the wizard. Every net with
   `MARK_DEBUG=true` is pre-selected; click **Next**.
3. **Sample of data depth**: `4096` (fits in one 36 Kb BRAM per 32-bit
   probe pair). Leave "Capture control" enabled so you can use advanced
   triggers. The probed nets are clocked by the core clock (`clk_core` in
   `fpga_top.vhd`; by default 80 MHz on Basys3 and ZedBoard), so the
   ILA must use that clock.
   Click **Next** -> **Finish**.
4. **File -> Save Constraints** prompts for a target XDC. **Do not** pick
   `constraints/<board>.xdc` -- Vivado would append `create_debug_core` /
   `connect_debug_port` lines to your hand-written pin/clock constraints and
   rewrite the file on every save. Instead:
   - Select **Create a new file**, name it `debug.xdc`, location
     `<Local to Project>`. The XDC is written under
     `build/vivado/<test>/minrv32_<test>.srcs/constrs_1/new/debug.xdc`, which
     is inside the already-gitignored `build/` tree -- no repo pollution, no
     `.gitignore` change needed.
   - To remove the ILA later, either delete the debug core
     (**Debug -> Delete Debug Core**) or drop `debug.xdc` from the fileset;
     your board XDC stays clean either way.
   - On a subsequent Set Up Debug run, double-check the wizard still points
     at `debug.xdc` -- it can default back to the board XDC.

Synthesis (`synth_1`) does not need a reset -- the debug core is stitched
in during implementation, so the synthesized netlist is still valid.

---

## 6. Implementation + bitstream

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

If you inserted the ILA after `impl_1` had already run once, the debug
XDC makes the existing implementation steps out-of-date and Vivado
refuses to advance a stale run
(`ERROR: [Vivado 12-1088] Step 'write_bitstream' needs to be reset`).
Reset first and relaunch through bitstream:

```tcl
reset_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
```

The bitstream lands under
`build/vivado/<test>/minrv32_<test>.runs/impl_1/fpga_top.bit` (Vivado names
the bitstream after the synthesis top, which is `fpga_top`).

---

## 7. Program the FPGA and press the reset button

```tcl
open_hw_manager
connect_hw_server
open_hw_target

# List what the JTAG chain is showing before you pick an index:
get_hw_devices

# Select the FPGA fabric (PL) device from the chain and program it. The
# bitstream file name is derived from the synthesis top, i.e. `fpga_top.bit`.
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE \
  [file join [get_property DIRECTORY [current_project]] \
             minrv32_full_core.runs impl_1 fpga_top.bit] \
  [current_hw_device]
program_hw_devices [current_hw_device]
```

**Picking the right index from `get_hw_devices`:**

- **Pure-PL boards (Basys3, Artix/Kintex/Virtex parts):** there is only one
  device in the chain, so index `0` is correct.
- **Zynq / Zynq UltraScale+ boards (ZedBoard, Pynq-Z*, Ultra96, ...):** the
  JTAG chain typically has **two** devices -- the ARM Processing System
  (e.g. `arm_dap_0`) **and** the FPGA fabric (e.g. `xc7z020_1`). The PL
  (programmable logic) is usually index `1`, not `0`. Run `get_hw_devices`
  first and pick the FPGA entry by name:

  ```tcl
  # Zynq: prefer name-based selection over a hard-coded index.
  current_hw_device [get_hw_devices xc7z020_1]
  ```

  The exact name depends on the part (e.g. `xc7z020_1` for ZedBoard,
  `xczu7ev_1` for ZCU104, `xc7z010_1` for a Zynq-7010 board). Match the
  part to the `<board|part>` you passed to `-tclargs` when creating the
  project.

### How reset behaves on the board

The `reset` input is **active-high** (`if reset = '1' then ...` in the RTL)
and is routed to the centre pushbutton:

- Basys3: **btnC** (pin `U18`)
- ZedBoard: **BTNC** (pin `P16`)

At configuration time the FPGA loads all flip-flops and BRAMs with their
declared VHDL init values. `fpga_top` holds the core in reset until the MMCM
output is stable, then releases it, so the core starts fetching from PC = 0
-- you do **not** need to press the button for the first run.

Pressing and holding the button **re-asserts reset** (the core halts at
whatever state the pipeline FFs fall into while reset is high), and
releasing the button **re-starts the program from PC = 0**. So the pushbutton
acts as a "restart" button: useful for re-running the test without
reprogramming the bitstream, and for synchronising a scope/ILA trigger with
the start of execution.

---

## 8. Validate a program via the signature window (ILA capture)

On Xilinx 7-series / Zynq-7000 parts there is no generic JTAG command that
reads an inferred BRAM directly (`get_hw_memories` / `read_hw_memory` are
only present for MIG / HBM / MicroBlaze-BMM flows). The zero-extra-RTL
alternative that works on every 7-series board is the **Integrated Logic
Analyzer (ILA)** inserted in Section 5: probe the DMEM write interface,
trigger on stores into the signature window, and let Vivado capture the
signature words as the program writes them.

The signature layout is fixed across the repo:

- DMEM base: `0x2000_0000`
- Signature base: `0x2000_0100` (DMEM byte offset `0x100`)
- Full-core signature: 10 words (`tests/isa/full_core.sig`)

### 8.1 Configure the trigger and capture the signature

1. Program the board (Section 7).
2. The **ILA dashboard** auto-opens in the Hardware Manager.
3. In the **Trigger Setup** pane, add two conditions and AND them:

   | Probe                | Operator | Radix | Value            |
   |----------------------|----------|-------|------------------|
   | `dmem_write_en_i`    | `==`     | `[B]` | `1`              |
   | `dmem_addr_i[31:0]`  | `==`     | `[H]` | `2000_01XX`      |

   (Vivado's ILA trigger uses `X` -- uppercase -- as the don't-care
   wildcard in hex radix; `?` is rejected. The `XX` covers any signature
   byte offset `0x00`..`0xFF`, which for a 10-word signature spans
   `0x2000_0100`..`0x2000_0127`.)

4. **Capture Setup** (optional but helpful): "Store only when trigger is
   true" with depth 16 -- exactly enough for a 10-word signature plus a
   bit of headroom.
5. Click **Run Trigger**, then reset the core (press **BTNC** on
   ZedBoard / **btnC** on Basys3) to restart execution from PC = 0.
6. When the trigger fires, the waveform shows one sample per signature
   store. Read `dmem_addr_i` / `dmem_wdata_i` off each sample. Convert
   `dmem_addr_i - 0x2000_0100` to a word index and compare each
   `dmem_wdata_i` to the matching line of `tests/isa/<test>.sig`.

### 8.2 Quick sanity-check commands (Hardware Manager Tcl)

```tcl
# Verify an ILA is present and list its probes:
get_hw_ilas
get_hw_probes -of_objects [get_hw_ilas]

# Arm, wait, then dump the latest capture to CSV (word index and value):
run_hw_ila [get_hw_ilas]
wait_on_hw_ila [get_hw_ilas]
write_hw_ila_data -csv_file sig_capture.csv [current_hw_ila_data \
  [get_hw_ilas]]
```

If every captured `dmem_wdata_i` matches the corresponding line of
`tests/isa/full_core.sig`, the program passed on hardware.

### 8.3 Rapid program iteration with `updatemem` (not currently supported)

It would be convenient to swap the IMEM/DMEM contents of an existing
bitstream with `updatemem` and avoid re-running synthesis +
implementation for every new test. **This flow is not available in this
project today**, for a concrete tool reason: `updatemem` needs an `.mmi`
file, and Vivado's `write_mem_info` only generates one for designs that
contain a MicroBlaze (or other recognised soft processor) or use the
`XPM_MEMORY_*` library primitives. Running it on this project produces:

```
ERROR: [Common 17-69] Command failed: This design does not have any
processors or XPM Libraries. In order to create the .mmi the design
must have processors. Failed to create the mem info file.
```

Our [`rtl/imem_dp.vhd`](../rtl/imem_dp.vhd) and [`rtl/dmem.vhd`](../rtl/dmem.vhd)
are plain VHDL arrays with TEXTIO initialisation -- inferred BRAMs that
GHDL, XSim and Vivado synthesis all elaborate from the same source.
That portability is the reason the simulation flow works on Linux
without Xilinx tooling, and it is also the reason `write_mem_info`
refuses to emit an MMI here.

#### Working alternatives

- **Re-run implementation** for each new program. The Tcl script already
  bakes the hex paths into the BRAM `INIT_xx` parameters at synthesis
  time, so the only step needed is:

  ```bash
  ./scripts/build_prog.sh tests/isa/factorial.c factorial
  vivado -source scripts/vivado_project.tcl -tclargs factorial zedboard
  ```

  followed by `launch_runs synth_1 ... ; launch_runs impl_1 ...` per
  Sections 4 and 6. On a small design like this one a full
  synth + impl + bitstream pass takes a few minutes -- not as fast as
  `updatemem`, but always correct and requires no extra files.

- **Migrate the BRAMs to `XPM_MEMORY_*` primitives.** Would unlock
  `write_mem_info` and let this section work as originally written, but
  XPM macros are Xilinx-only and would break the GHDL simulation path,
  so this is not a free swap.

- **Hand-author the MMI** by walking placed `RAMB36E1` cells
  (`get_cells -hier -filter {REF_NAME =~ RAMB36*}`) and emitting the
  `<Processor>`/`<AddressSpace>`/`<BitLane>` blocks against their LOCs.
  Doable, but the file has to be regenerated whenever placement shifts,
  and a small Tcl helper has to be written and maintained.

If `updatemem`-based iteration becomes a real bottleneck, the
XPM_MEMORY route is the cleanest of the three; until then, re-running
`impl_1` is the supported path. See Xilinx *UG898* for the full
`updatemem` / MMI reference.

---

## 9. Custom boards

If your board isn't Basys3 or ZedBoard:

1. **Copy an existing XDC** from `constraints/` to `constraints/<myboard>.xdc`.
2. **Replace the two `PACKAGE_PIN` values** for `clk` and `reset` with your
   board's values from the vendor reference manual (look for "system clock
   source" and "user pushbuttons"). Set `create_clock -period` to your board
   clock period (10.000 ns for 100 MHz).
3. Pass it as the third `-tclargs` argument. If the board clock is not
   100 MHz, also pass `--clk-in-mhz`. Choose the core clock with `--clk-mhz`
   (see [Changing the core clock](#changing-the-core-clock)):

   ```bash
   vivado -source scripts/vivado_project.tcl -tclargs \
          full_core xc7a100tcsg324-1 constraints/myboard.xdc \
          --clk-in-mhz 100 --clk-mhz 80
   ```

   The script prints a warning when the XDC `create_clock` period does not
   match the board clock.

Only `clk`, `reset`, and `led` need real pins. The synthesis top
(`fpga_top`) doesn't expose `DataAdr`, `WriteData`, `MemWrite`, `MemRead`,
`MemWStrb` as top-level ports -- they are captured internally and XOR-
folded into `led` so synthesis keeps the whole datapath, and the
individual signals are observed on-board via the ILA (Section 8). No
`PACKAGE_PIN` entries are needed (or valid) for them. Route `led` to any
on-board LED pin on your custom board.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
