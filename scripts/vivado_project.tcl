# ----------------------------------------------------------------------------
# vivado_project.tcl - automated Vivado project setup for MinRV32
#
# Usage:
#   vivado -mode batch -source scripts/vivado_project.tcl -tclargs \
#          <test> <board|part> [<xdc_path>] [--clk-mhz <f>] [--clk-in-mhz <f>]
#
# or to open the project in the GUI afterwards:
#   vivado -source scripts/vivado_project.tcl -tclargs \
#          <test> <board|part> [<xdc_path>] [--clk-mhz <f>] [--clk-in-mhz <f>]
#
# Arguments:
#   <test>        Test name under tests/isa/ (e.g. full_core, addi_only).
#                 The script expects build/<test>.text.hex, build/<test>.data.hex,
#                 and tests/isa/<test>.sig to already exist -- run
#                 `./scripts/build_prog.sh tests/isa/<test>.{c,S} <test>` first.
#
#   <board|part>  One of the named boards (sets part, default XDC, board
#                 clock and default core clock):
#                     basys3    -> xc7a35tcpg236-1, constraints/basys3.xdc,
#                                  board clock 100 MHz, core clock 80 MHz
#                     zedboard  -> xc7z020clg484-1, constraints/zedboard.xdc,
#                                  board clock 100 MHz, core clock 80 MHz
#                 Or a raw Xilinx part number (e.g. xc7a100tcsg324-1). In that
#                 case you MUST also pass <xdc_path> to get a usable synthesis
#                 run; simulation works without any XDC. The board clock is
#                 then 100 MHz unless --clk-in-mhz says otherwise.
#
#   <xdc_path>    Optional. Overrides the default board XDC. Use this to point
#                 at your own pin map for a custom board.
#
#   --clk-mhz <f> Optional. Core clock frequency in MHz. The core clock is
#                 made from the board clock by an MMCM in rtl/fpga_top.vhd.
#                 The script picks the MMCM settings that give the highest
#                 frequency that is not above <f>, and prints it.
#
#   --clk-in-mhz <f>  Optional. Board clock frequency in MHz. It must match
#                 the create_clock period in the XDC file; the script prints
#                 a warning when it does not.
#
# What the script does:
#   1. Creates a Vivado project under build/vivado/<test>/
#   2. Imports every rtl/*.vhd as design source and every sim/*.vhd as
#      simulation source, then flips all of them to VHDL-2008.
#   3. Sets synthesis top to `fpga_top` (minimal-IO wrapper around `top`,
#      exposing only clk/reset on the pad ring) and simulation top to
#      `tb_minrv32` (which still drives the full `top` interface).
#   4. Sets synthesis generics (IMEM/DMEM sizes, absolute hex paths, and the
#      MMCM settings for the core clock).
#   5. Sets simulation generics (IMEM/DMEM hex + expected .sig + word count)
#      and the simulation run time ("all": run until the testbench stops).
#   6. Attaches the board XDC (or user-supplied XDC) to constrs_1.
# ----------------------------------------------------------------------------

# --- Parse arguments: options anywhere, the rest are positional -------------
set clk_mhz    ""
set clk_in_mhz ""
set positional {}
for {set i 0} {$i < $argc} {incr i} {
  set a [lindex $argv $i]
  switch -- $a {
    --clk-mhz    { incr i; set clk_mhz    [lindex $argv $i] }
    --clk-in-mhz { incr i; set clk_in_mhz [lindex $argv $i] }
    default      { lappend positional $a }
  }
}
foreach {name val} [list --clk-mhz $clk_mhz --clk-in-mhz $clk_in_mhz] {
  if {$val ne "" && (![string is double -strict $val] || $val <= 0)} {
    puts "ERROR: $name needs a positive number of MHz, got '$val'"
    exit 1
  }
}

if {[llength $positional] < 2} {
  puts "ERROR: expected at least 2 args: <test> <board|part> \[<xdc>\]\
        \[--clk-mhz <f>\] \[--clk-in-mhz <f>\]"
  puts "       e.g. -tclargs full_core basys3"
  exit 1
}

set test   [lindex $positional 0]
set target [lindex $positional 1]
set xdc    [expr {[llength $positional] >= 3 ? [lindex $positional 2] : ""}]

# Resolve repo root as the parent of this script's directory.
set repo [file normalize [file join [file dirname [info script]] ..]]

# --- Map named boards to (part, default XDC) --------------------------------
# clk_in = board clock (MHz); clk = default core clock (MHz). The default
# core clock is close to the highest frequency at which implementation still
# meets timing on that board. Measured with Vivado 2024.2 and the full_core
# program, as core clock period minus worst setup slack after implementation
# at 80 MHz: about 81.1 MHz on both boards (worst slack 0.175 ns on basys3
# and 0.174 ns on zedboard). The margin is small: if a change to the RTL
# makes 80 MHz fail, 75 MHz is the safe fallback (--clk-mhz 75).
array set BOARDS {
  basys3,part    xc7a35tcpg236-1
  basys3,xdc     constraints/basys3.xdc
  basys3,clk_in  100
  basys3,clk     80
  zedboard,part  xc7z020clg484-1
  zedboard,xdc   constraints/zedboard.xdc
  zedboard,clk_in 100
  zedboard,clk   80
}
set DEFAULT_CLK_IN_MHZ 100
set DEFAULT_CLK_MHZ    80

if {[info exists BOARDS($target,part)]} {
  set part $BOARDS($target,part)
  if {$xdc eq ""} { set xdc [file join $repo $BOARDS($target,xdc)] }
  if {$clk_in_mhz eq ""} { set clk_in_mhz $BOARDS($target,clk_in) }
  if {$clk_mhz eq ""}    { set clk_mhz    $BOARDS($target,clk) }
  puts "INFO: board '$target' -> part $part, xdc $xdc"
} else {
  set part $target
  if {$clk_in_mhz eq ""} { set clk_in_mhz $DEFAULT_CLK_IN_MHZ }
  if {$clk_mhz eq ""}    { set clk_mhz    $DEFAULT_CLK_MHZ }
  if {$xdc ne "" && [file pathtype $xdc] ne "absolute"} {
    set xdc [file join $repo $xdc]
  }
  puts "INFO: treating '$target' as raw Xilinx part"
  if {$xdc eq ""} {
    puts "WARN: no XDC supplied; synthesis will run without pin constraints"
  }
}

# --- MMCM settings for the core clock ----------------------------------------
# core clock = clk_in * M / (D * O). Limits of the 7-series MMCM for the
# slowest speed grade (-1), from the Artix-7 (DS181) and Zynq-7000 (DS187)
# data sheets: oscillator (clk_in * M / D) 600..1200 MHz, phase detector input
# (clk_in / D) 10..450 MHz, M 2..64, D 1..106, O 1..128, and at most 464 MHz
# at the output (the global clock buffer limit). Only whole numbers
# are used for M and O. The search keeps the highest frequency that is not
# above the requested one; on a tie it keeps the higher oscillator frequency.
proc mmcm_settings {clk_in clk} {
  set best {}
  set best_f 0.0
  set best_vco 0.0
  set lim [expr {min(double($clk), 464.0)}]
  for {set d 1} {$d <= 106} {incr d} {
    set pfd [expr {double($clk_in) / $d}]
    if {$pfd < 10.0 || $pfd > 450.0} { continue }
    for {set m 2} {$m <= 64} {incr m} {
      set vco [expr {$pfd * $m}]
      if {$vco < 600.0 || $vco > 1200.0} { continue }
      set o [expr {int(ceil($vco / $lim - 1e-9))}]
      if {$o < 1} { set o 1 }
      if {$o > 128} { continue }
      set f [expr {$vco / $o}]
      if {$f > $lim + 1e-9} { continue }
      if {$f > $best_f + 1e-9 || (abs($f - $best_f) <= 1e-9 && $vco > $best_vco)} {
        set best [list $m $d $o]
        set best_f $f
        set best_vco $vco
      }
    }
  }
  return [list $best $best_f]
}

lassign [mmcm_settings $clk_in_mhz $clk_mhz] mmcm core_mhz
if {$mmcm eq ""} {
  puts "ERROR: the MMCM cannot make a core clock of at most $clk_mhz MHz from a\
        $clk_in_mhz MHz board clock"
  exit 1
}
lassign $mmcm mmcm_mult mmcm_divclk mmcm_out_div
set clk_in_period_ps [expr {int(round(1.0e6 / $clk_in_mhz))}]
puts [format "INFO: board clock %.3f MHz, requested core clock %.3f MHz" \
        $clk_in_mhz $clk_mhz]
puts [format "INFO: core clock %.3f MHz (period %.3f ns): MMCM_MULT=%d MMCM_DIVCLK=%d MMCM_OUT_DIV=%d" \
        $core_mhz [expr {1000.0 / $core_mhz}] $mmcm_mult $mmcm_divclk $mmcm_out_div]

# Warn when the XDC clock period does not match the board clock.
if {$xdc ne "" && [file exists $xdc]} {
  set fh [open $xdc r]
  set xdc_text [read $fh]
  close $fh
  if {[regexp -line {^\s*create_clock\s.*-period\s+([0-9.]+)} $xdc_text -> xdc_period]} {
    set want [expr {1000.0 / $clk_in_mhz}]
    if {abs($xdc_period - $want) > 0.001} {
      puts [format "WARN: XDC create_clock period is %s ns, but the board clock\
                    is %.3f MHz (%.3f ns). Fix the XDC or pass --clk-in-mhz." \
              $xdc_period $clk_in_mhz $want]
    }
  }
}

# --- Verify required build artifacts ----------------------------------------
set build    [file join $repo build]
set imem_hex [file join $build "$test.text.hex"]
set dmem_hex [file join $build "$test.data.hex"]
set sig_file [file join $repo tests isa "$test.sig"]

foreach f [list $imem_hex $dmem_hex $sig_file] {
  if {![file exists $f]} {
    puts "ERROR: required file missing: $f"
    puts "       run: ./scripts/build_prog.sh tests/isa/$test.\{c,S\} $test"
    exit 1
  }
}

# Count signature words (non-blank lines in the .sig file).
set sig_words 0
set fh [open $sig_file r]
while {[gets $fh line] >= 0} {
  if {[string trim $line] ne ""} { incr sig_words }
}
close $fh
puts "INFO: signature words = $sig_words (from $sig_file)"

# --- Create project ---------------------------------------------------------
set proj_dir [file join $build vivado $test]
file mkdir [file join $build vivado]
create_project -force minrv32_$test $proj_dir -part $part

# --- Add RTL sources --------------------------------------------------------
set rtl_files [glob -nocomplain [file join $repo rtl *.vhd]]
add_files -norecurse $rtl_files
foreach f $rtl_files {
  set_property file_type {VHDL 2008} [get_files $f]
}

# --- Add simulation sources -------------------------------------------------
set sim_files [glob -nocomplain [file join $repo sim *.vhd]]
add_files -fileset sim_1 -norecurse $sim_files
foreach f $sim_files {
  set_property file_type {VHDL 2008} [get_files $f]
}

# --- Tops -------------------------------------------------------------------
set_property top fpga_top      [current_fileset]
set_property top tb_minrv32    [get_filesets sim_1]

# --- Synthesis generics ------------------------------------------------------
# The hex paths must be absolute: Vivado's elaborator reads the files (with
# VHDL TEXTIO, see rtl/mem_init_pkg.vhd) from its own run directory.
set_property generic \
  "IMEM_WORDS=2048 DMEM_WORDS=2048 \
   IMEM_INIT_FILE=$imem_hex \
   DMEM_INIT_FILE=$dmem_hex \
   CLK_IN_PERIOD_PS=$clk_in_period_ps \
   MMCM_MULT=$mmcm_mult \
   MMCM_DIVCLK=$mmcm_divclk \
   MMCM_OUT_DIV=$mmcm_out_div" \
  [current_fileset]

# --- Simulation generics ----------------------------------------------------
set_property generic \
  "IMEM_INIT_FILE=$imem_hex \
   DMEM_INIT_FILE=$dmem_hex \
   EXPECTED_FILE=$sig_file \
   SIGNATURE_WORDS=$sig_words \
   MAX_CYCLES=5000 \
   HALT_ON_PASS=true" \
  [get_filesets sim_1]

# Run the simulation until the testbench stops it (on TEST PASSED, or on a
# failure after MAX_CYCLES). Vivado's default run time is 1000 ns, which ends
# before full_core passes (at about 28 us).
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# --- Constraints ------------------------------------------------------------
if {$xdc ne ""} {
  if {![file exists $xdc]} {
    puts "ERROR: XDC not found: $xdc"
    exit 1
  }
  add_files -fileset constrs_1 -norecurse $xdc
}

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts ""
puts "Project ready at: $proj_dir/minrv32_$test.xpr"
puts ""
puts "Next steps:"
puts "  * Run behavioral simulation:  launch_simulation"
puts "  * Run synthesis:              launch_runs synth_1 -jobs 4"
puts "  * Run implementation:         launch_runs impl_1 -jobs 4"
puts "  * Generate bitstream:         launch_runs impl_1 -to_step write_bitstream -jobs 4"
