.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li t0, SIGNATURE_BASE

    li t1, 5
    addi t2, t1, -3
    sw t2, 0(t0)

    li t1, 0x0f0f0f0f
    andi t2, t1, 0x0f0
    sw t2, 4(t0)

    ori t2, zero, 0x6ab
    sw t2, 8(t0)

    li t1, 0x12345678
    xori t2, t1, 0x7ff
    sw t2, 12(t0)

    li t1, -5
    slti t2, t1, 3
    sw t2, 16(t0)

    slti t2, t1, -6
    sw t2, 20(t0)

    li t1, -1
    sltiu t2, t1, 0
    sw t2, 24(t0)

    li t1, 0
    sltiu t2, t1, -1
    sw t2, 28(t0)

    li t1, 1
    slli t2, t1, 6
    sw t2, 32(t0)

    li t1, 0xf0000000
    srli t2, t1, 4
    sw t2, 36(t0)

    li t1, -16
    srai t2, t1, 2
    sw t2, 40(t0)

end_loop:
    beq zero, zero, end_loop
