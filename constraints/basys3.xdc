# ----------------------------------------------------------------------------
# Basys3 (xc7a35tcpg236-1) pin assignments for MinRV32 top.vhd
#
# Only clk, reset, and the activity led need to reach real pins; the internal
# observation nets in top.vhd (DataAdr, WriteData, MemWrite, MemRead, MemWStrb)
# are observed via the ILA (MARK_DEBUG), so they do NOT need LOC constraints
# here.
#
# Board reference: Digilent Basys3 Reference Manual.
# ----------------------------------------------------------------------------

# 100 MHz on-board oscillator -> clk (pin W5)
set_property PACKAGE_PIN W5 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
# The core does not run at this clock. An MMCM in rtl/fpga_top.vhd makes the
# core clock from it (80 MHz by default on this board; change it with --clk-mhz in
# scripts/vivado_project.tcl). Vivado derives the core clock constraint from
# this board clock constraint and the MMCM settings, so the period below must
# be the real board clock period.
create_clock -name sys_clk -period 10.000 [get_ports clk]

# Center pushbutton (btnC) -> reset (pin U18)
set_property PACKAGE_PIN U18 [get_ports reset]
set_property IOSTANDARD LVCMOS33 [get_ports reset]

# Execution-activity LED -> LD0 (pin U16). Driven inside fpga_top by an
# XOR-reduction of every observation signal from `top`, so the pattern has
# no specific meaning -- it is there to give synthesis a pin sink (otherwise
# the whole datapath would be optimised away as dead code) and to provide a
# visible "alive" indicator while the core is running.
set_property PACKAGE_PIN U16 [get_ports led]
set_property IOSTANDARD LVCMOS33 [get_ports led]

# Configuration bank voltage for bitstream generation
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
