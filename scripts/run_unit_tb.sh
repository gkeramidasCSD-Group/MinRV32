#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run_unit_tb.sh - Run a self-checking unit-level VHDL testbench (sim/unit/*).
#
# Usage:
#   ./scripts/run_unit_tb.sh [--wave|--vcd|--fst] [--verbose] <tb-name>
#
# Examples:
#   ./scripts/run_unit_tb.sh alu          # runs sim/unit/tb_alu.vhd
#   ./scripts/run_unit_tb.sh --fst regfile
#
# Outputs:
#   build/waves/<tb-name>.{fst|vcd|ghw} (optional)
#   build/ghdl/run_unit_tb/... (GHDL work library and elaboration executables)
#
# Environment variables:
#   GHDL         : ghdl binary to use (default: ghdl)
#   GHDL_STD     : VHDL standard/options (default: --std=08)
#   GHDL_WORKDIR : override the GHDL work directory (default: build/ghdl/...)
#   VERBOSE      : set to 1 to echo commands (or pass --verbose)
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/run_unit_tb.sh [--wave|--vcd|--fst] [--verbose] <tb-name>

Runs a unit-level self-checking testbench from sim/unit/. The <tb-name> can be
given with or without the tb_ prefix.

Waveforms (optional) are written under build/waves/.
GHDL compilation artifacts are isolated under build/ghdl/ to keep the repo root
clean and to avoid collisions when running multiple testbenches in parallel.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v -- "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# Extract the VHDL standard tag (e.g. "08") from GHDL-style arguments.
# Used to build a unique work directory per --std= setting.
std_tag_from_args() {
  local arg
  for arg in "$@"; do
    if [[ "${arg}" == --std=* ]]; then
      echo "${arg#--std=}"
      return 0
    fi
  done
  echo "custom"
}

# ------------------------------ Parse CLI flags ------------------------------

WAVE_KIND=""
VERBOSE=${VERBOSE:-0}
args=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    --wave)
      WAVE_KIND="wave"
      ;;
    --vcd)
      WAVE_KIND="vcd"
      ;;
    --fst)
      WAVE_KIND="fst"
      ;;
    -v|--verbose)
      VERBOSE=1
      ;;
    *)
      args+=("${arg}")
      ;;
  esac
done

if [[ ${#args[@]} -ne 1 ]]; then
  usage
  exit 1
fi

TB_NAME=${args[0]}
# Allow the user to omit the "tb_" prefix for convenience.
if [[ "${TB_NAME}" != tb_* ]]; then
  TB_NAME="tb_${TB_NAME}"
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# Source VHDL file lists (glob-based, no hardwired order).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vhdl_sources.sh"

TB_FILE="${REPO_ROOT}/sim/unit/${TB_NAME}.vhd"
if [[ ! -f "${TB_FILE}" ]]; then
  die "Unit testbench not found: ${TB_FILE}"
fi

# ----------------------- Configure GHDL simulation ---------------------------

BUILD_DIR="${REPO_ROOT}/build"
WAVE_DIR="${BUILD_DIR}/waves"
mkdir -p "${BUILD_DIR}"

GHDL=${GHDL:-ghdl}
require_cmd "${GHDL}"

GHDL_STD_STR=${GHDL_STD:---std=08}
read -r -a GHDL_STD_ARGS <<<"${GHDL_STD_STR}"
STD_TAG=$(std_tag_from_args "${GHDL_STD_ARGS[@]}")
STD_TAG_SAFE=${STD_TAG//[^[:alnum:]_.-]/_}

TB_NAME_SAFE=${TB_NAME//[^[:alnum:]_.-]/_}

WAVE_ARGS=()
if [[ -n "${WAVE_KIND}" ]]; then
  mkdir -p "${WAVE_DIR}"
  case "${WAVE_KIND}" in
    wave) WAVE_ARGS=(--wave="${WAVE_DIR}/${TB_NAME_SAFE}.ghw") ;;
    vcd)  WAVE_ARGS=(--vcd="${WAVE_DIR}/${TB_NAME_SAFE}.vcd") ;;
    fst)  WAVE_ARGS=(--fst="${WAVE_DIR}/${TB_NAME_SAFE}.fst") ;;
    *) die "Unknown waveform kind: ${WAVE_KIND}" ;;
  esac
fi

WORK_ROOT="${REPO_ROOT}/build/ghdl"
if [[ -n "${GHDL_WORKDIR:-}" ]]; then
  WORKDIR="${GHDL_WORKDIR}"
else
  WORKDIR="${WORK_ROOT}/run_unit_tb/${TB_NAME_SAFE}/${STD_TAG_SAFE}"
fi
mkdir -p "${WORKDIR}"

# ---------------------- Import, elaborate, and run ----------------------------
# `ghdl -i` registers sources in the work library without requiring dependency
# order; `ghdl -m` resolves the dependency graph and compiles automatically.
# Run inside a subshell so that `cd` and `set -x` (when --verbose is used)
# do not leak into the parent environment.
(
  cd "${WORKDIR}"
  if [[ "${VERBOSE}" != 0 ]]; then
    set -x
  fi

  "${GHDL}" -i "${GHDL_STD_ARGS[@]}" --workdir="${WORKDIR}" \
    "${VHDL_RTL_SOURCES[@]}" "${TB_FILE}"

  "${GHDL}" -m "${GHDL_STD_ARGS[@]}" --workdir="${WORKDIR}" "${TB_NAME}"

  "${GHDL}" -r "${GHDL_STD_ARGS[@]}" --workdir="${WORKDIR}" "${TB_NAME}" \
    --assert-level=error \
    "${WAVE_ARGS[@]}"
)
