# ----------------------------------------------------------------------------
# ZedBoard (xc7z020clg484-1) pin assignments for MinRV32 top.vhd
#
# Only clk, reset, and the activity led need to reach real pins; the internal
# observation nets in top.vhd are observed via the ILA (MARK_DEBUG).
#
# The ZedBoard also has a Zynq PS; this project uses only the PL side, so the
# PS is not wired up here. The PL 100 MHz clock source is the on-board
# oscillator routed to GCLK (Y9), and we use the center pushbutton BTNC for
# reset.
#
# Board reference: Avnet ZedBoard Hardware User's Guide.
# ----------------------------------------------------------------------------

# 100 MHz PL clock (GCLK) -> clk (pin Y9)
set_property PACKAGE_PIN Y9 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
# The core does not run at this clock. An MMCM in rtl/fpga_top.vhd makes the
# core clock from it (80 MHz by default on this board; change it with --clk-mhz in
# scripts/vivado_project.tcl). Vivado derives the core clock constraint from
# this board clock constraint and the MMCM settings, so the period below must
# be the real board clock period.
create_clock -period 10.000 -name sys_clk [get_ports clk]

# Center pushbutton (BTNC) -> reset (pin P16)
set_property PACKAGE_PIN P16 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

# Execution-activity LED -> LD0 (pin T22). Driven inside fpga_top by an
# XOR-reduction of every observation signal from `top`, so the pattern has
# no specific meaning -- it is there to give synthesis a pin sink (otherwise
# the whole datapath would be optimised away as dead code) and to provide a
# visible "alive" indicator while the core is running.
set_property PACKAGE_PIN T22 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]
