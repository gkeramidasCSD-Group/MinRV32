# Scripts overview

This directory contains the helper utilities used throughout the project. The following sections summarize what each script does, the typical way to invoke it, and noteworthy options or environment variables.

## `build_prog.sh`

Compiles a freestanding RV32I C (or assembly) program into the artifacts consumed by the pipelined core's instruction/data memories.

- Wraps the project's bare-metal GCC invocation and applies the linker script (`link.ld`) (see [Instruction tests](instruction_tests.md) for the build/test flow).
- Produces an ELF plus `.text` and `.data` hex files under `build/` so they can be loaded into `imem` and `dmem`.
- The same hex files can also be passed to the memories' `INIT_HEX` generics during synthesis (Vivado reads them into BRAM automatically).
- When given a `.c` source it also emits a GCC-generated `.S` listing beside the other artifacts, making it easy to inspect the compiler's output.
- Prints the resulting `.text`/`.data` image sizes so you can sanity-check they fit in the default 8 KiB IMEM / 8 KiB DMEM windows.
- Honors `RISCV_GCC`, `RISCV_OBJCOPY`, `PYTHON`, `CFLAGS`, and `LDFLAGS` environment variables if you need a different toolchain, interpreter, or flags (flag overrides are whitespace-split).
- If you changed the VHDL memory sizes, set `IMEM_BYTES` / `DMEM_BYTES` so the size warnings match your configuration.
- `LINKER_SCRIPT` selects a different linker script (default `link.ld`). `gen_golden.sh` uses it to pass `link_spike.ld`.

Usage:

```sh
./scripts/build_prog.sh path/to/prog.c [output_base]
```

Provide either a `.c` or `.S` file; the optional second argument changes the base name of the generated artifacts.

## `run_test.sh`

Builds and runs a single ISA test (assembly `.S` or C `.c`) using GHDL.

- Detects whether the requested test has an assembly or C source and calls `build_prog.sh` with the matching file.
- Launches `ghdl` to analyze, elaborate, and run `sim/tb_minrv32.vhd` with the freshly generated instruction/data hex images for the pipelined core.
- Compares the signature written by the DUT to `tests/isa/<name>.sig`, failing fast on mismatches.
- Adjustable knobs: `GHDL` (binary path), `GHDL_STD` (e.g., `--std=08`), `MAX_CYCLES` (simulation runtime budget), and `FORWARDING_ENABLE` (set to `false` to force stall-only hazards) can be overridden via the environment. Use `VERBOSE=1` (or `--verbose`) to echo the underlying GHDL commands.
- GHDL work libraries/elaboration binaries are written under `build/ghdl/` by default (override with `GHDL_WORKDIR`) to keep the repo root clean and to avoid collisions when running multiple tests in parallel.
- Optional flags: `--trace` prints per-instruction decode/control traces (including hazard stall/flush/forward decisions when they occur); `--fst`/`--vcd`/`--wave` dumps waveforms under `build/waves/`.
- When authoring a new test, generate its `tests/isa/<name>.sig` with [`gen_golden.sh`](#gen_goldensh) (Spike) before rerunning for regressions.

Usage:

```sh
./scripts/run_test.sh test_name
```

The script looks for `tests/isa/test_name.S` or `.c` plus `tests/isa/test_name.sig`.

## `run_unit_tb.sh`

Runs a self-checking unit-level VHDL testbench under `sim/unit/` using GHDL.

- Useful for module bring-up (ALU, regfile, hazard unit, etc.) without running the full core or building a program image.
- Accepts `--fst`/`--vcd`/`--wave` to dump waveforms under `build/waves/`.
- Like `run_test.sh`, it isolates GHDL work libraries under `build/ghdl/` (override with `GHDL_WORKDIR`) and supports `VERBOSE=1` / `--verbose` for debugging.

Usage:

```sh
./scripts/run_unit_tb.sh alu
./scripts/run_unit_tb.sh --fst regfile
```

Waveforms land under `build/waves/` and can be opened with GTKWave (or use `./scripts/view_wave.sh`):

```sh
./scripts/view_wave.sh build/waves/tb_regfile.fst
```

## `run_unit_tests.sh`

Batch driver that iterates over every `sim/unit/tb_*.vhd` unit testbench and calls `run_unit_tb.sh` on each one.

Usage:

```sh
./scripts/run_unit_tests.sh
./scripts/run_unit_tests.sh --fst
```

## `view_wave.sh`

Opens a waveform file in GTKWave (if installed).

Usage:

```sh
./scripts/view_wave.sh build/waves/full_core.fst
```

## `run_tests.sh`

Batch driver that iterates over every test with a `.sig` file in `tests/isa/` and calls `run_test.sh` on each one.

- Runs all tests to completion and prints a pass/fail summary at the end. Exits with code 1 if any test failed.
- Useful for regression runs after RTL changes.
- Pass `--trace` to enable per-instruction tracing for every test, and `--verbose` to echo the underlying `run_test.sh` commands.

Usage:

```sh
./scripts/run_tests.sh
./scripts/run_tests.sh --trace
```

Set `MAX_CYCLES`, `GHDL`, or `GHDL_STD` beforehand if all runs should share the same overrides.

## `gen_golden.sh`

Generates the golden signature of a test with the Spike ISA simulator.

- Builds `tests/isa/<name>.S` or `.c` (or a source path) with `build_prog.sh` and `LINKER_SCRIPT=link_spike.ld`, then runs `build/<name>.spike.elf` on Spike in debug mode.
- Runs `SPIKE_MAX_INSNS` instructions (default 1000000), checks that the PC is parked in the final self-loop, and reads the signature window at `0x2000_0100`.
- Writes `build/golden/<name>.sig` (lowercase hex, one word per line). `--write` copies it to `tests/isa/<name>.sig`, and `--check` compares it with that file (exit 1 on a mismatch).
- The word count is `--words N`, or the line count of the existing `tests/isa/<name>.sig`.
- Environment variables: `SPIKE`, `SPIKE_ISA` (default `rv32i`), `SPIKE_MAX_INSNS`, plus the `build_prog.sh` variables. `--verbose` echoes the Spike command.
- Spike reserves `0x0` for its debug module and boot ROM, so code is linked at `0x8000_0000` for Spike, while data memory and the signature window keep their addresses. A signature word that holds a raw code or `.rodata` address therefore differs by `0x8000_0000`; see [code-address differences](instruction_tests.md#golden-signatures-with-spike-code-address-differences).
- Needs Spike; see [Prerequisites](prerequisites.md#24-spike).
- To run a program on Spike yourself and step through it in Spike's debugger, see [Running a program on Spike by hand](instruction_tests.md#running-a-program-on-spike-by-hand) and [Stepping through a program in Spike's debugger](instruction_tests.md#stepping-through-a-program-in-spikes-debugger).

Usage:

```sh
./scripts/gen_golden.sh factorial                   # print + save build/golden/factorial.sig
./scripts/gen_golden.sh --check factorial           # compare with tests/isa/factorial.sig
./scripts/gen_golden.sh --words 4 --write my_test   # create tests/isa/my_test.sig
```

## `check_goldens.sh`

Batch driver that runs `gen_golden.sh --check` for every test with a `.sig` file in `tests/isa/` and prints a match/differ summary (exit 1 if any differ). Use it after editing a test source to confirm that the checked-in goldens still agree with Spike.

```sh
./scripts/check_goldens.sh
```

## `clean.sh`

Removes build/test artifacts to return the tree to a pristine state.

- Deletes the `build/` directory, the `tmp/` directory (if present), the `work-obj*.cf` cache produced by GHDL, and any GHDL elaboration executables matching `e~*` in the repo root.
- Safe to run repeatedly; it reports "Nothing to clean." when no targets are found.

Usage:

```sh
./scripts/clean.sh
```

## `health_check.sh`

Runs every step of the project flow, one after the other, and reports which steps pass. Use it to check that the whole repository still works after a change.

- It first copies the repository into a new output directory and runs every step in that copy. Your working tree is not changed. The copy holds the files that git tracks plus the untracked files that git does not ignore, so changes you have not committed are tested too.
- By default the run starts in the background and is detached from the terminal (it uses `setsid` and `nohup`). The script prints the log location and returns at once. The run continues if you close the terminal. Pass `--foreground` to run it in the current terminal instead.
- The default output directory is `build/health/<date-time>/`. Pass `--out <dir>` to choose another one.
- If a step needs a tool that is not installed, the step is reported as `SKIP` and the run continues. Pass `--strict` to count skipped steps as a failure.
- A Vivado step also fails when `vivado_project.tcl` warns that the `create_clock` period in the XDC file does not match the board clock.
- The `clean` step runs `clean.sh` inside the copy. It is skipped when an earlier step failed, so the build files stay available for debugging.

The steps, in run order:

| Step | What it runs |
|------|--------------|
| `build` | `build_prog.sh` on every `tests/isa/*.c` and `*.S` file |
| `unit` | `run_unit_tests.sh` |
| `waves` | `run_unit_tb.sh --fst alu` and `run_test.sh --fst addi_only`, then checks that both `.fst` files exist |
| `isa` | `run_tests.sh` |
| `trace` | `run_test.sh --trace addi_only`, then checks that the output has trace lines |
| `stall` | `run_tests.sh` with `FORWARDING_ENABLE=false` |
| `golden` | `check_goldens.sh` |
| `schematic` | `gen_schematic.sh --all` |
| `digitaljs` | `gen_schematic.sh --digitaljs alu`, and `gen_schematic.sh --digitaljs` with `--mem-init` for `top` with the `full_core` program, then checks that the memories were loaded |
| `vivado-sim` | `vivado_project.tcl` for the first board, then an XSim simulation that must print `TEST PASSED` |
| `vivado-impl` | For each board: `vivado_project.tcl`, synthesis, implementation and bitstream. It fails if the synthesized design has no `MARK_DEBUG` nets or no block RAM cells, or if setup timing is not met. It prints the core clock and an estimate of the highest core clock that would meet timing (core clock period minus the worst slack, as a frequency). |
| `latex` | `make -C latex pdf` |
| `clean` | `clean.sh`, then checks that `build/` was removed |

The script does not run `view_wave.sh`, because it opens a window. It does not program a board or capture the signature with the ILA, because both need a connected board. [Manual testing](manual_testing.md) shows how to run every test by hand, including these, and what each result must look like.

Options:

- `--only <list>` and `--skip <list>` select steps by name (comma-separated).
- `--boards <list>` sets the boards for the Vivado steps (default `basys3,zedboard`).
- `--vivado-test <name>` sets the program used by the Vivado steps (default `full_core`).
- `--clk-mhz <f>` sets the core clock in MHz for the Vivado steps. It is passed to `vivado_project.tcl` (see [Vivado instructions -- changing the core clock](vivado_instructions.md#changing-the-core-clock)). Without it, each board uses its default.
- `--jobs <n>` sets the number of parallel Vivado jobs (default 4).
- `--xilinx-dir <dir>` points to the Xilinx install directory. The script sources the newest `<dir>/Vivado/<version>/settings64.sh` for the Vivado steps only. The `XILINX_DIR` environment variable does the same. Without it, the script uses `vivado` from `PATH`.
- `--path <dir>` adds a directory to the front of `PATH` (repeatable). Use it for tools that are not on `PATH`, such as the RISC-V GCC or Spike.

Output directory contents:

| Path | Content |
|------|---------|
| `health.log` | Full log of the run |
| `summary.txt` | One line per step with its result |
| `status` | `RUNNING` while the run is going, then `PASS` or `FAIL` |
| `pid` | Process ID of a background run |
| `logs/` | One log file per step, plus the Vivado logs |
| `reports/<board>/` | Vivado utilization and timing reports, and the bitstream |
| `repo/` | The copy of the repository that the steps ran in |

Usage:

```sh
./scripts/health_check.sh --xilinx-dir /tools/Xilinx \
    --path /opt/riscv/bin --path /opt/spike/bin
tail -f build/health/<date-time>/health.log

./scripts/health_check.sh --foreground --skip vivado-sim,vivado-impl
```

In the foreground mode the exit status is 0 when no step failed and 1 otherwise. In the background mode, read the `status` file.

## `gen_schematic.sh`

Generates schematic and interactive-simulation artifacts of RTL modules using the Yosys open-synthesis suite with its GHDL VHDL frontend plugin, netlistsvg for static SVG rendering, and (optionally) yosys2digitaljs for the interactive DigitalJS simulator.

The pipeline is: **VHDL -> ghdl (yosys-plugin-ghdl) -> Yosys synthesis -> JSON netlist -> {netlistsvg -> SVG, yosys2digitaljs -> DigitalJS JSON}**.

- Automatically discovers every `entity` declaration in `rtl/` and builds a name-to-file mapping.
- By default, hierarchy is preserved: sub-module instantiations appear as labelled boxes.
- Supports four hierarchy-control modes (see examples below).
- Optionally produces Graphviz DOT/PNG output (`--dot`) via the Yosys `show` command - useful for a more gate-level/graph-oriented view.
- Optionally produces DigitalJS-compatible JSON (`--digitaljs`) that can be uploaded to [digitaljs.tilk.eu](https://digitaljs.tilk.eu/). DigitalJS is both a schematic viewer **and** an interactive simulator: you drive inputs in the browser and see values propagate through the gates, which makes it a useful visual companion to GTKWave for leaf modules (ALU, regfile, extend) and to the GHDL full-core tests for the whole pipeline (see [Memory initialization for DigitalJS](#memory-initialization-for-digitaljs) for loading firmware so the pipeline steps with realistic state).
- Supports `--mem-init <module>=<hex-file>` to inject real firmware contents into memory cells before the DigitalJS conversion, so the interactive simulation starts with the correct instruction and data images rather than all-zeros (see [Memory initialization for DigitalJS](#memory-initialization-for-digitaljs) below).
- Auto-detects `GHDL_PREFIX` so the yosys-ghdl plugin finds the correct VHDL standard libraries regardless of which GHDL backend (mcode vs gcc) is installed.
- Honors `YOSYS`, `NETLISTSVG`, and `GHDL_STD` environment variables for tool path / standard overrides.

DigitalJS complements -- but does not replace -- GHDL and Vivado XSim. The signature-checked `run_test.sh` / `run_tests.sh` flows remain the authoritative pass/fail; DigitalJS is for interactive exploration. See [Learning path -- step 3](learning_path.md#3-explore-simple-modules-interactively-with-digitaljs) and [step 5](learning_path.md#5-step-through-the-full-pipeline-in-digitaljs-with-firmware-loaded) for where each tool fits in the educational flow.

### Hierarchy control

| Mode | Flag | Effect |
|------|------|--------|
| Hierarchical (default) | *(none)* | Every sub-module is a labelled box |
| Full flatten | `--flat` | Expand everything down to primitives |
| Depth-limited flatten | `--flat N` | Expand N levels; deeper modules stay as boxes |
| Selective expand | `--expand <entity>` | Expand only the named sub-module(s); repeatable |

### Clock and reset handling in DigitalJS

The `--digitaljs` post-processor also invokes `yosys2digitaljs`'s `io_ui()`
helper, which remaps the raw port devices into simulator-UI widgets so the
exported circuit is immediately runnable in the browser without manual
clock toggling:

| Original device | Becomes | Why |
|---|---|---|
| 1-bit `Input` named `clk`/`clock` | `Clock` (self-ticking, `propagation: 100`) | auto-runs the clock when the simulation starts |
| other 1-bit `Input` (e.g. `reset`) | `Button` (one-click pulse) | click once to pulse reset; no manual hold |
| multi-bit `Input` | `NumEntry` (typeable number field) | enter hex/dec instead of bit-by-bit toggling |
| 1-bit `Output` | `Lamp` (LED indicator) | visible at a glance |
| multi-bit `Output` | `NumDisplay` | readable number instead of a bit vector |

Upload the JSON to [digitaljs.tilk.eu](https://digitaljs.tilk.eu/) and the
clock starts running as soon as you press the simulator's run button;
clicking the `reset` button once pulses the reset line so the core comes
out of reset into normal operation.

### Memory initialization for DigitalJS

Yosys synthesis excludes the `synthesis translate_off` blocks in
`mem_init_pkg.vhd`, so the `init_mem()` file-I/O call is never executed
during synthesis.  Every `$mem`/`$mem_v2` cell in the netlist ends up
with an all-'x' INIT parameter, which DigitalJS treats as all-zeros at
simulation start.

The `--mem-init <module>=<hex-file>` flag (repeatable) patches the INIT
parameter of the named module's memory cell with the real firmware content
before `yosys2digitaljs` runs the conversion.  Pass the `.text.hex` file
for `imem_dp` and the `.data.hex` file for `dmem` -- both are produced by
`build_prog.sh`.

**Limitation:** `--mem-init` works on the hierarchical (default) netlist
where `imem_dp` and `dmem` appear as distinct modules.  In a fully
flattened design (`--flat`) the modules are merged into the top level and
the injection is a no-op; a warning is printed in that case.

Usage:

```sh
# List all discoverable RTL entities
./scripts/gen_schematic.sh --list

# Generate a hierarchical SVG schematic for a single module
./scripts/gen_schematic.sh alu

# Hierarchical schematic with DOT/PNG too
./scripts/gen_schematic.sh --dot riscvpipe

# Full flatten (expand everything to primitives)
./scripts/gen_schematic.sh --flat riscvpipe

# Depth-limited flatten (expand 1 level only)
./scripts/gen_schematic.sh --flat 1 riscvpipe

# Depth-limited flatten (expand 2 levels)
./scripts/gen_schematic.sh --flat 2 datapath_pipe

# Selective expand: show datapath_pipe internals, keep everything else as boxes
./scripts/gen_schematic.sh --expand datapath_pipe riscvpipe

# Selective expand: expand two specific sub-modules
./scripts/gen_schematic.sh --expand datapath_pipe --expand controller_pipe riscvpipe

# Generate schematics for every RTL entity
./scripts/gen_schematic.sh --all

# Custom output directory
./scripts/gen_schematic.sh -o docs/diagrams fetch_stage

# Produce DigitalJS JSON (upload to https://digitaljs.tilk.eu/ for interactive view)
./scripts/gen_schematic.sh --digitaljs riscvpipe

# DigitalJS JSON with real firmware loaded into imem and dmem
./scripts/gen_schematic.sh --digitaljs \
    --mem-init imem_dp=build/full_core.text.hex \
    --mem-init dmem=build/full_core.data.hex \
    top

# Combine flags: flatten 1 level + DigitalJS + DOT
./scripts/gen_schematic.sh --flat 1 --digitaljs --dot riscvpipe
```

Outputs land under `build/schematics/` by default:

| File | Description |
|------|-------------|
| `<entity>.json` | Yosys JSON netlist (intermediate) |
| `<entity>.svg` | **Main schematic** - clean, labelled boxes and wires (netlistsvg) |
| `<entity>.dot` | Graphviz DOT file (only with `--dot`) |
| `<entity>.png` | Rendered DOT graph (only with `--dot`) |
| `<entity>.digitaljs.json` | DigitalJS-compatible JSON (only with `--digitaljs`); contains firmware init data when `--mem-init` is used |

**Prerequisites:** see [Prerequisites](prerequisites.md) for
the full install list; the schematic tools specifically need Yosys,
yosys-plugin-ghdl, Graphviz, netlistsvg, and optionally yosys2digitaljs.

## `mem_init_inject.py`

Post-processing helper that patches a Yosys JSON netlist so DigitalJS
simulation starts with real firmware instead of all-zeros.

- Called automatically by `gen_schematic.sh` whenever `--mem-init` is
  given; can also be run standalone for scripted flows.
- Reads the named modules from the JSON, locates their `$mem`/`$mem_v2`
  cells, and overwrites the INIT parameter with the binary encoding of the
  hex file contents.
- Module matching uses a prefix rule so GHDL-mangled names (e.g.
  `imem_dp_bf8b4530`) are found even before `--demangle` has been applied.
- Hex file format: one unsigned 32-bit word per line, as produced by
  `bin_to_hex.py` (e.g. `deadbeef`). Blank lines are ignored; words
  beyond the cell's depth are silently discarded.
- Prints a `[INIT]` line for each cell patched, or a `[WARN]` if no
  matching cells are found.
- The JSON file is modified in place.

Usage:

```sh
python3 scripts/mem_init_inject.py \
    --json build/schematics/riscvpipe.json \
    --module imem_dp --hex build/full_core.text.hex \
    --module dmem    --hex build/full_core.data.hex
```

Each `--module` / `--hex` pair must appear together and in order.

## `vhdl_sources.sh`

Shared helper sourced by `run_test.sh` and `run_unit_tb.sh` to provide ordered VHDL compile lists.

- Defines `VHDL_RTL_SOURCES` (packages first, leaf modules, stage wrappers, decoders, controller/datapath, memories, top) and `VHDL_SIM_SOURCES` (trace wrappers + testbench).
- Uses an include guard (`__MINRV32_VHDL_SOURCES_SH_LOADED`) so it can be safely sourced multiple times.
- Keeps the GHDL analysis order in one place: adding/removing RTL files only requires updating this file, not every script.

This file is not meant to be executed directly - it is sourced by other scripts:

```sh
source "${REPO_ROOT}/scripts/vhdl_sources.sh"
```

## `bin_to_hex.py`

Utility used by `build_prog.sh` to transform raw binary blobs into newline-delimited 32-bit hex words.

- Reads a little-endian binary file, pads it to a 4-byte boundary, and writes each word as `XXXXXXXX` (lowercase hex plus newline).
- Works for both `.text` and `.data` outputs so the simple VHDL memories can load them via `$readmemh`-style mechanisms.
- Advanced use: `--word-bytes N` changes the output word width (default: 4 bytes).

Usage:

```sh
python3 scripts/bin_to_hex.py --input build/prog.data.bin --output build/prog.data.hex
```

The script creates the output directory if needed, so it can be invoked standalone as well as through `build_prog.sh`.

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
