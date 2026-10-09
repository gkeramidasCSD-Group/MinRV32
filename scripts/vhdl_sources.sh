#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# vhdl_sources.sh
#
# Shared VHDL source lists used by the simulation and schematic scripts.
#
# Source discovery is automatic (glob-based) -- adding or removing a .vhd file
# under rtl/ or sim/ is picked up without editing this file.
#
# This file is intended to be *sourced* by other bash scripts:
#   source "${REPO_ROOT}/scripts/vhdl_sources.sh"
# -----------------------------------------------------------------------------

if [[ -z "${__MINRV32_VHDL_SOURCES_SH_LOADED:-}" ]]; then
  __MINRV32_VHDL_SOURCES_SH_LOADED=1

  VHDL_SOURCES_SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  VHDL_SOURCES_REPO_ROOT=$(cd -- "${VHDL_SOURCES_SCRIPT_DIR}/.." && pwd)

  # RTL sources: all .vhd files under rtl/.
  # Order does not matter -- the consuming scripts use `ghdl -i` (import) which
  # registers files in the work library without requiring dependency order.
  # Dependency resolution happens at elaboration time (`ghdl -m`).
  mapfile -t VHDL_RTL_SOURCES < <(
    find "${VHDL_SOURCES_REPO_ROOT}/rtl" -maxdepth 1 -name '*.vhd' -print | sort
  )

  # Simulation-only sources: top-level sim/ files (trace wrappers + testbench).
  # Unit testbenches under sim/unit/ are handled individually by run_unit_tb.sh.
  mapfile -t VHDL_SIM_SOURCES < <(
    find "${VHDL_SOURCES_REPO_ROOT}/sim" -maxdepth 1 -name '*.vhd' -print | sort
  )
fi
