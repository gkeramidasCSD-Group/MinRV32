OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 8K
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
  } > DMEM AT>IMEM

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
