.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li t0, SIGNATURE_BASE

    la t1, test_word
    lw t2, 0(t1)
    sw t2, 0(t0)

    la t1, test_half
    lh t2, 0(t1)
    sw t2, 4(t0)

    lh t2, 2(t1)
    sw t2, 8(t0)

    lhu t2, 2(t1)
    sw t2, 12(t0)

    la t1, test_bytes
    lb t2, 1(t1)
    sw t2, 16(t0)

    lbu t2, 3(t1)
    sw t2, 20(t0)

    la t1, store_buf
    li t2, 0xdeadbeef
    sw t2, 0(t1)
    lw t3, 0(t1)
    sw t3, 24(t0)

    li t2, 0x1234
    sh t2, 4(t1)
    lhu t3, 4(t1)
    sw t3, 28(t0)

    li t2, -128
    sb t2, 6(t1)
    lb t3, 6(t1)
    sw t3, 32(t0)

end_loop:
    beq zero, zero, end_loop

.section .data
.align 4
test_bytes:
    .byte 0x11, 0x82, 0x7f, 0xff

.align 2
test_half:
    .half 0x1234, 0xfedc

.align 4
test_word:
    .word 0x11223344

.align 4
store_buf:
    .space 16
