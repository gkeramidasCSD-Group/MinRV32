.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li t0, SIGNATURE_BASE

    li t1, 5
    addi t2, t1, -3
    sw t2, 0(t0)

    li t1, -5
    addi t2, t1, 6
    sw t2, 4(t0)

    li t1, 0x7ff
    addi t2, t1, 1
    sw t2, 8(t0)

    li t1, -2048
    addi t2, t1, -1
    sw t2, 12(t0)

    li t1, 0
    addi t2, t1, 0
    sw t2, 16(t0)

    addi t2, zero, -123
    sw t2, 20(t0)

end_loop:
    beq zero, zero, end_loop
