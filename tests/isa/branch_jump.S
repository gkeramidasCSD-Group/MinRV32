.section .text
.globl _start
.equ SIGNATURE_BASE, 0x20000100

_start:
    li s0, SIGNATURE_BASE

    # BEQ not taken
    li t1, 1
    li t2, 2
    li t3, 0x11111111
    sw t3, 0(s0)
    beq t1, t2, beq_unexpected
    j beq_done
beq_unexpected:
    sw zero, 0(s0)
beq_done:

    # BEQ taken
    sw zero, 4(s0)
    li t1, 5
    li t2, 5
    beq t1, t2, beq_taken
    j beq_taken_fail
beq_taken:
    li t3, 0x22222222
    sw t3, 4(s0)
beq_taken_fail:

    # BNE taken
    sw zero, 8(s0)
    li t1, 7
    li t2, 9
    bne t1, t2, bne_taken
    j bne_taken_fail
bne_taken:
    li t3, 0x33333333
    sw t3, 8(s0)
bne_taken_fail:

    # BNE not taken
    li t1, 4
    li t2, 4
    li t3, 0x44444444
    sw t3, 12(s0)
    bne t1, t2, bne_unexpected
    j bne_done
bne_unexpected:
    sw zero, 12(s0)
bne_done:

    # BLT taken
    sw zero, 16(s0)
    li t1, -5
    li t2, 3
    blt t1, t2, blt_taken
    j blt_done
blt_taken:
    li t3, 0x55555555
    sw t3, 16(s0)
blt_done:

    # BGE taken
    sw zero, 20(s0)
    li t1, 6
    li t2, -2
    bge t1, t2, bge_taken
    j bge_done
bge_taken:
    li t3, 0x66666666
    sw t3, 20(s0)
bge_done:

    # BLTU taken
    sw zero, 24(s0)
    li t1, 1
    li t2, -1
    bltu t1, t2, bltu_taken
    j bltu_done
bltu_taken:
    li t3, 0x77777777
    sw t3, 24(s0)
bltu_done:

    # BGEU taken
    sw zero, 28(s0)
    li t1, -1
    li t2, 1
    bgeu t1, t2, bgeu_taken
    j bgeu_done
bgeu_taken:
    li t3, 0x88888888
    sw t3, 28(s0)
bgeu_done:

    # JAL test
    jal x1, jal_target
jal_return:
    la t4, jal_return
    sub t4, x1, t4
    sw t4, 36(s0)
    j jal_done
jal_target:
    li t3, 0x99999999
    sw t3, 32(s0)
    jalr x0, 0(x1)
jal_done:

    # JALR test
    la t5, jalr_target
    jalr x5, 0(t5)
jalr_return:
    la t6, jalr_return
    sub t6, x5, t6
    sw t6, 44(s0)
    j end_loop
jalr_target:
    li t3, 0xaaaaaaaa
    sw t3, 40(s0)
    jalr x0, 0(x5)

end_loop:
    beq zero, zero, end_loop
