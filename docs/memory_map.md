# Memory map and linker script

This repository uses a Harvard-style pipelined microarchitecture with dedicated instruction and data memories. Software needs to understand that layout so the toolchain can place code, constants, and writable state in the right windows. This note describes the memory map implemented by the RTL, why the address ranges were chosen, and how the provided linker script (`link.ld`) enforces those rules.

## Address map overview

| Region                      | Base address  | Size   | Access       | Purpose |
| --------------------------- | ------------- | ------ | ------------ | ------- |
| Instruction memory (`IMEM`) | `0x0000_0000`  | 8 KiB  | read/execute | Holds `.text`, `.init`, and `.rodata`. The PC comes out of reset at this base, so the first instruction is fetched at address zero. |
| Data memory (`DMEM`)        | `0x2000_0000`  | 8 KiB  | read/write   | Stores `.data`, `.sdata`, `.bss`, stack, and the architectural signature buffer (`0x2000_0100`). |

Key motivations for this split:

- **Simple reset sequencing** - the PC inside the pipelined core resets to zero. Placing `.text` at `0x0000_0000` means the core starts executing the very first word in instruction memory without any relocation logic or vector table.
- **Clear Harvard separation** - dedicating the upper address bit (bit 29) to data makes it trivial to tell, just by looking at an address, whether it should be routed to instruction or data memory. It also prevents buggy code from accidentally executing data or writing into instructions.
- **Room for growth** - the 0x2000_0000 offset leaves a large unused region between IMEM and DMEM so peripherals or MMIO devices can be inserted later without moving existing binaries.
- **Deterministic stack and signature area** - the linker defines `__stack_top = 0x2000_0000 + 8KiB` (default `0x2000_2000`), so `_start` can initialize the stack pointer into the upper end of DMEM. Test programs share a well-known signature window at `0x2000_0100`, matching the expectations baked into `sim/tb_minrv32.vhd`.

Because the provided memories are only 8 KiB (IMEM) and 8 KiB (DMEM), any program that exceeds those limits will either fail to link or clobber data. The scripts print the generated `.text.hex` and `.data.hex` sizes, so you can check that they fit before loading them into the simulator.

The VHDL `imem_dp` and `dmem` blocks do not perform any high-bit address decoding - they simply mask the address down to the configured depth (for example, `raddr <= to_integer(unsigned(addr(31 downto 2))) mod WORDS;` in `rtl/dmem.vhd`). Software still uses the full logical addresses (`0x0000_xxxx` for IMEM, `0x2000_xxxx` for DMEM) so the linker keeps code and data in separate regions, but these simple memories only see the low bits when indexing their arrays. If you later wrap the core in a larger SoC, you can insert proper decode logic around these memories without changing the linker script or the compiled binaries.

**Data-side reads from the text region (`.rodata` access):** Because `.rodata` constants are placed in instruction memory alongside `.text`, load instructions that target addresses below `DMEM_BASE_ADDR` (`0x2000_0000`) need to read from IMEM, not DMEM. The `top.vhd` module uses a dual-port instruction memory (`imem_dp`), with port A serving instruction fetch and port B serving data-side reads. A registered mux-select (`use_imem_w`) steers the read-data path: when the load address is below `DMEM_BASE_ADDR`, the result comes from `imem_dp` port B; otherwise it comes from `dmem`. The one-cycle register delay on the mux-select aligns with the BRAM output timing.

Related implementation detail: `mem_access_unit` only consumes the low address
bits of `alu_result` for byte strobes and alignment, so higher address bits are
intentionally unused in that helper.

## Linker script walkthrough

`link.ld` is a conventional bare-metal RISC-V linker script tailored to the memory map above. It serves three purposes:

1. **Locks sections to explicit regions** - `.text` and `.rodata` are emitted into `IMEM`, while `.data` and `.bss` are placed in `DMEM`.
2. **Ensures loaders get the right initialization data** - `.data` lives in DMEM at runtime but is copied out of the ELF image that resides in IMEM (`AT>IMEM` in the script). This allows `scripts/build_prog.sh` to extract a `prog.data.hex` file containing the initialized bytes that should be written into data memory before releasing reset.
3. **Defines runtime symbols** - `ENTRY(_start)` makes sure the linker keeps the startup stub at the beginning of `.text`, and `__stack_top` gives the bootstrap code a reliable stack pointer location.

Important snippets from `link.ld`:

```ld
MEMORY {
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 8K
  DMEM (rw) : ORIGIN = 0x20000000, LENGTH = 8K
}

.text : {
  *(.init)
  *(.text .text.*)
  *(.rodata .rodata.*)
} > IMEM

.data : ALIGN(4) {
  *(.data .data.*)
  *(.sdata .sdata.*)
} > DMEM AT>IMEM

.bss (NOLOAD) : ALIGN(4) {
  __bss_start = .;
  *(.sbss .sbss.*)
  *(.bss .bss.*)
  *(COMMON)
  __bss_end = .;
} > DMEM

PROVIDE(__stack_top = ORIGIN(DMEM) + LENGTH(DMEM));
```

- The `MEMORY` block declares the two address ranges so `ld` knows where each section can live and what attributes (read/execute vs. read/write) they carry.
- `.text` globs `.init`, `.text`, and `.rodata` so both code and constants land in the instruction memory hex file. The project links everything as read/execute only.
- `.data` is aligned to 4 bytes, dropped into DMEM, but tagged `AT>IMEM` so its load image is bundled with `.text` in the ELF. That way the simulator knows what values need to be pre-initialized in data memory before execution starts.
- `.bss` is marked `NOLOAD`. The runtime (or simulator) just zeroes the range between `__bss_start` and `__bss_end` at reset, rather than expecting those bytes in the ELF.
- `__stack_top` ends up at `0x2000_0000 + 8K` (default `0x2000_2000`), which matches the top of DMEM. Startup assembly simply loads this symbol into `sp`, and the stack grows downward within data memory.

### How `build_prog.sh` uses the linker script

`scripts/build_prog.sh` passes `-T link.ld` to `riscv64-unknown-elf-gcc`, ensuring every program you compile for the core inherits these placement rules. After linking:

1. `objcopy` extracts `.text/.rodata` into `<name>.text.bin`, which is then converted into `<name>.text.hex` for instruction memory initialization.
2. `objcopy` extracts `.data/.sdata` into `<name>.data.bin`, later converted to `<name>.data.hex` for data memory initialization.
3. `.bss` remains zeroed at runtime, so no hex values need to be provided for that region.

### Spike variant: `link_spike.ld`

`scripts/gen_golden.sh` runs the tests on the Spike ISA simulator to produce the golden `.sig` files. Spike reserves the low address space for its debug module (`0x0000_0000`-`0x0000_0FFF`) and boot ROM (from `0x1000`), so instruction memory cannot sit at `0x0` there. `link_spike.ld` is a copy of `link.ld` with two changes: code moves to `0x8000_0000`, and `.data` is placed at its run address (no `AT>IMEM`), so Spike's ELF loader preloads DMEM the same way `<name>.data.hex` does on the core.

| Item | MinRV32 (`link.ld`) | Spike (`link_spike.ld`) |
| --- | --- | --- |
| `.init`, `.text`, `.rodata` | `0x0000_0000` | `0x8000_0000` |
| `.data`, `.bss`, stack top | `0x2000_0000`... / `0x2000_2000` | same |
| signature window | `0x2000_0100` | same |

Because only code moves, a signature word differs between Spike and the core only when it holds a raw code or `.rodata` address. See [code-address differences](instruction_tests.md#golden-signatures-with-spike-code-address-differences).

Without `link.ld`, GCC would emit host-default addresses (often `0x8000_0000` for upstream RISC-V linker scripts), and the generated binaries would not match the instruction/data memories baked into the RTL. Keeping the custom script in-tree ensures every test, firmware image, or experiment lines up with the actual hardware implementation.

## Future work: one memory map for the core and Spike

The two linker scripts exist only because the core's IMEM sits at `0x0`, where Spike has its debug module. Spike does not accept memory there (`spike -m0x0:0x2000,...` exits with `devices at [0, 1000) and [0, 2000) overlap`). Spike's other devices are the boot ROM (`0x1000`), CLINT (`0x0200_0000`), PLIC (`0x0C00_0000`) and UART (`0x1000_0000`); DMEM at `0x2000_0000` overlaps none of them.

If the core's IMEM is moved to `0x8000_0000`, both the core and Spike can use one linker script. `0x8000_0000` is also the RAM base used by riscv-tests, riscv-arch-test, QEMU `virt` and Sail. The current layout does not affect the golden signatures as long as tests follow the [code-address rule](instruction_tests.md#golden-signatures-with-spike-code-address-differences), so this change is not needed now.

Proposed memory map:

| Region | Now | Proposed |
| --- | --- | --- |
| IMEM (`.init`, `.text`, `.rodata`), reset PC | `0x0000_0000` | `0x8000_0000` |
| DMEM, stack top, signature window | `0x2000_0000` / `0x2000_2000` / `0x2000_0100` | unchanged |

Required changes:

1. **Reset PC.** The PC register (`pc_reg` in `rtl/fetch_stage.vhd`) is a `pipe_reg` that resets to all zeros. Add a reset-value generic to `pipe_reg` (default zero, so the other pipeline registers do not change), plus a `RESET_PC` generic (default `x"80000000"`) passed down from `top`/`riscvpipe` to `fetch_stage`.
2. **Load-path decode.** `rtl/top.vhd` and `sim/top_trace.vhd` send a load to IMEM port B when `addr < DMEM_BASE_ADDR`. With IMEM above DMEM this test is wrong. Use `addr(31) = '1'` instead (IMEM at `0x8000_0000`, DMEM at `0x2000_0000`); it also needs less logic than the 32-bit compare.
3. **Memories.** No change: `imem_dp` and `dmem` index only the low address bits, so `0x8000_0000` maps to word 0.
4. **Linker script.** In `link.ld`, set `IMEM ORIGIN = 0x80000000` and remove `AT>IMEM` from `.data`. Nothing copies `.data` from its load address: the core preloads DMEM from `<name>.data.hex`, and `objcopy -j .data -O binary` writes the same bytes either way. Delete `link_spike.ld` and the `LINKER_SCRIPT=` override in `scripts/gen_golden.sh` (`build_prog.sh` can keep the variable as a general option).
5. **Documentation.** Update the address tables (this file, `docs/instruction_tests.md`, the LaTeX manual), remove the code-address differences section, and update examples that show PC values (trace excerpts, DigitalJS and ILA descriptions).

Results:

- Raw code and `.rodata` addresses (function pointers, `la`, `auipc`, link registers) give the same signature on both; the code-address rule is no longer needed.
- Existing `.sig` files stay valid, because no current test stores a raw code address.
- The PC no longer resets to zero, which the docs present as a simplification for teaching.
- Two differences remain: the registers the boot ROM sets and the cases where Spike traps (see [other differences](instruction_tests.md#golden-signatures-with-spike-other-differences)).

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
