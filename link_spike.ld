/*
 * link_spike.ld - Spike-only variant of link.ld, used by scripts/gen_golden.sh.
 *
 * Spike reserves the low address space for its debug module (0x0000_0000)
 * and boot ROM (0x1000), so IMEM cannot sit at 0x0 as it does on MinRV32.
 * Code (.init/.text/.rodata) is relinked to 0x8000_0000 (Spike's DRAM base);
 * DMEM, the stack and the signature window (0x2000_0100) keep their addresses.
 * A signature word that holds a raw code/.rodata address therefore differs by
 * 0x8000_0000 (see docs/instruction_tests.md, "code-address differences").
 *
 * .data is placed at its run address (no AT>IMEM), so Spike's ELF loader
 * preloads DMEM the same way build/<name>.data.hex does on the core.
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  IMEM (rx) : ORIGIN = 0x80000000, LENGTH = 8K
  DMEM (rw) : ORIGIN = 0x20000000, LENGTH = 8K
}

SECTIONS
{
  .text : {
    *(.init)
    *(.text .text.*)
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
  } > IMEM

  /* build_prog.sh copies only the output sections named here into the
     memory images, and the first word of the .text image is loaded at the
     start of IMEM. So .text must start at ORIGIN(IMEM), and no other section
     may be placed in front of it. Some toolchains (for example the RISC-V
     GCC that comes with AMD Vitis) add a .note.gnu.build-id section by
     default, which would land at ORIGIN(IMEM) and move .text up. */
  /DISCARD/ : {
    *(.note .note.*)
  }

  .data : ALIGN(4) {
    *(.data .data.*)
    *(.sdata .sdata.*)
  } > DMEM

  .bss (NOLOAD) : ALIGN(4) {
    __bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    __bss_end = .;
  } > DMEM

  PROVIDE(__stack_top = ORIGIN(DMEM) + LENGTH(DMEM));

  ASSERT(ADDR(.text) == ORIGIN(IMEM), ".text must start at ORIGIN(IMEM)")
}
