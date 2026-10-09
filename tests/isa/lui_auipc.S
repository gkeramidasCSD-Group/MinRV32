.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li t0, SIGNATURE_BASE

    lui t1, 0x12345
    addi t1, t1, 0x678
    sw t1, 0(t0)

    .option push
    .option norelax
1:  auipc t2, %pcrel_hi(pc_data)
    lw t3, %pcrel_lo(1b)(t2)
    .option pop
    sw t3, 4(t0)

end_loop:
    beq zero, zero, end_loop

.section .rodata
.align 4
pc_data:
    .word 0xcafebabe
