#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run_test.sh - Build and run a single ISA test on the pipelined core using GHDL.
#
# Usage:
#   ./scripts/run_test.sh [--trace] [--wave|--vcd|--fst] [--verbose] <test-name>
#
# Inputs:
#   tests/isa/<test-name>.S or tests/isa/<test-name>.c
#   tests/isa/<test-name>.sig   (expected signature words, one per line)
#
# Outputs:
#   build/<test-name>.{elf,text.hex,data.hex,...}
#   build/waves/<test-name>.{fst|vcd|ghw} (optional)
#   build/ghdl/run_test/... (GHDL work library and elaboration executables)
#
# Environment variables:
#   GHDL              : ghdl binary to use (default: ghdl)
#   GHDL_STD          : VHDL standard/options (default: --std=08)
#   MAX_CYCLES        : simulation cycle budget (default: 5000)
#   FORWARDING_ENABLE : 'true' or 'false' (default: true)
#   GHDL_WORKDIR      : override the GHDL work directory (default: build/ghdl/...)
#   VERBOSE           : set to 1 to echo commands (or pass --verbose)
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/run_test.sh [--trace] [--wave|--vcd|--fst] [--verbose] <test-name>

Builds tests/isa/<test-name>.S or .c (via scripts/build_prog.sh), then runs
sim/tb_minrv32.vhd under GHDL and compares the signature buffer against
tests/isa/<test-name>.sig.

Waveforms (optional) are written under build/waves/.
GHDL compilation artifacts are isolated under build/ghdl/ to keep the repo root
clean and to avoid collisions when running multiple tests in parallel.
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
# Used to build a unique work directory per --std= setting, so that parallel
# runs with different standards don't collide.
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

TRACE_ENABLE=false
WAVE_KIND=""
VERBOSE=${VERBOSE:-0}

args=()
for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    -t|--trace)
      TRACE_ENABLE=true
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

# ----------------------------- Resolve paths ---------------------------------

TEST_NAME=${args[0]}
TEST_NAME_SAFE=${TEST_NAME//[^[:alnum:]_.-]/_}  # sanitise for filesystem use

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# Source VHDL file lists (glob-based, no hardwired order).
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vhdl_sources.sh"

ASM_SRC="${REPO_ROOT}/tests/isa/${TEST_NAME}.S"
C_SRC="${REPO_ROOT}/tests/isa/${TEST_NAME}.c"
EXPECTED="${REPO_ROOT}/tests/isa/${TEST_NAME}.sig"

if [[ -f "${ASM_SRC}" ]]; then
  TEST_SRC="${ASM_SRC}"
elif [[ -f "${C_SRC}" ]]; then
  TEST_SRC="${C_SRC}"
else
  die "Test source not found (.S or .c): ${ASM_SRC} / ${C_SRC}"
fi
[[ -f "${EXPECTED}" ]] || die "Expected signature file not found: ${EXPECTED}"

# ----------------------- Build the test program ------------------------------

BUILD_DIR="${REPO_ROOT}/build"
mkdir -p "${BUILD_DIR}"
WAVE_DIR="${BUILD_DIR}/waves"

BUILD_PROG="${REPO_ROOT}/scripts/build_prog.sh"
[[ -x "${BUILD_PROG}" ]] || die "Missing or non-executable script: ${BUILD_PROG}"
"${BUILD_PROG}" "${TEST_SRC}" "${TEST_NAME}"

IMEM_HEX="${BUILD_DIR}/${TEST_NAME}.text.hex"
DMEM_HEX="${BUILD_DIR}/${TEST_NAME}.data.hex"
[[ -f "${IMEM_HEX}" ]] || die "Missing IMEM hex file: ${IMEM_HEX}"
[[ -f "${DMEM_HEX}" ]] || die "Missing DMEM hex file: ${DMEM_HEX}"

# Count non-blank lines in the expected signature file (one word per line).
# NOTE: Avoid `grep -c` here because `set -e` treats a "0 matches" exit status
# as an error; `awk` reliably returns 0 and exits successfully.
SIG_WORDS=$(awk 'NF { c++ } END { print c+0 }' "${EXPECTED}")
if [[ ${SIG_WORDS} -le 0 ]]; then
  die "Expected signature file is empty: ${EXPECTED}"
fi

# ----------------------- Configure GHDL simulation ---------------------------

GHDL=${GHDL:-ghdl}
require_cmd "${GHDL}"

GHDL_STD_STR=${GHDL_STD:---std=08}
read -r -a GHDL_STD_ARGS <<<"${GHDL_STD_STR}"
STD_TAG=$(std_tag_from_args "${GHDL_STD_ARGS[@]}")
STD_TAG_SAFE=${STD_TAG//[^[:alnum:]_.-]/_}

# Validate forwarding toggle - only 'true' or 'false' are accepted because
# the VHDL generic is typed as boolean.
FORWARDING_ENABLE=${FORWARDING_ENABLE:-true}
FORWARDING_ENABLE=${FORWARDING_ENABLE,,}  # normalise to lowercase
case "${FORWARDING_ENABLE}" in
  true|false) ;;
  *) die "FORWARDING_ENABLE must be 'true' or 'false' (got: ${FORWARDING_ENABLE})" ;;
esac

# ---- Waveform dump (optional) ----
WAVE_ARGS=()
if [[ -n "${WAVE_KIND}" ]]; then
  mkdir -p "${WAVE_DIR}"
  case "${WAVE_KIND}" in
    wave) WAVE_ARGS=(--wave="${WAVE_DIR}/${TEST_NAME_SAFE}.ghw") ;;
    vcd)  WAVE_ARGS=(--vcd="${WAVE_DIR}/${TEST_NAME_SAFE}.vcd") ;;
    fst)  WAVE_ARGS=(--fst="${WAVE_DIR}/${TEST_NAME_SAFE}.fst") ;;
    *) die "Unknown waveform kind: ${WAVE_KIND}" ;;
  esac
fi

# ---- GHDL work directory (isolated per test / standard / forwarding) ----
WORK_ROOT="${REPO_ROOT}/build/ghdl"
if [[ -n "${GHDL_WORKDIR:-}" ]]; then
  WORKDIR="${GHDL_WORKDIR}"
else
  fwd_tag="fwd_${FORWARDING_ENABLE}"
  WORKDIR="${WORK_ROOT}/run_test/${TEST_NAME_SAFE}/${STD_TAG_SAFE}/${fwd_tag}"
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
    "${VHDL_RTL_SOURCES[@]}" "${VHDL_SIM_SOURCES[@]}"

  "${GHDL}" -m "${GHDL_STD_ARGS[@]}" --workdir="${WORKDIR}" tb_minrv32

# GHDL's -g flags override the VHDL generic defaults at runtime.
# Each -gNAME=VALUE replaces the corresponding generic's default
# value in the entity declaration.
  "${GHDL}" -r "${GHDL_STD_ARGS[@]}" --workdir="${WORKDIR}" tb_minrv32 \
    -gIMEM_INIT_FILE="${IMEM_HEX}" \
    -gDMEM_INIT_FILE="${DMEM_HEX}" \
    -gEXPECTED_FILE="${EXPECTED}" \
    -gSIGNATURE_ADDR=16#20000100# \
    -gSIGNATURE_WORDS="${SIG_WORDS}" \
    -gMAX_CYCLES="${MAX_CYCLES:-5000}" \
    -gFORWARDING_ENABLE="${FORWARDING_ENABLE}" \
    -gTRACE_ENABLE="${TRACE_ENABLE}" \
    --assert-level=error \
    "${WAVE_ARGS[@]}"
)
