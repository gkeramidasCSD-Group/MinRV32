.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li t0, SIGNATURE_BASE

    li t1, 5
    li t2, 7
    add t3, t1, t2
    sw t3, 0(t0)

    sub t3, t1, t2
    sw t3, 4(t0)

    and t3, t1, t2
    sw t3, 8(t0)

    or t3, t1, t2
    sw t3, 12(t0)

    xor t3, t1, t2
    sw t3, 16(t0)

    li t1, -3
    li t2, 4
    slt t3, t1, t2
    sw t3, 20(t0)

    slt t3, t2, t1
    sw t3, 24(t0)

    li t1, 1
    li t2, -1
    sltu t3, t1, t2
    sw t3, 28(t0)

    sltu t3, t2, t1
    sw t3, 32(t0)

    li t1, 1
    li t2, 4
    sll t3, t1, t2
    sw t3, 36(t0)

    li t1, -2
    li t2, 1
    srl t3, t1, t2
    sw t3, 40(t0)

    sra t3, t1, t2
    sw t3, 44(t0)

end_loop:
    beq zero, zero, end_loop
