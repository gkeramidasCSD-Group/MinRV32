#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# gen_golden.sh - Generate the golden signature of a test with the Spike ISA
#                 simulator (the reference model for tests/isa/<name>.sig).
#
# Usage:
#   ./scripts/gen_golden.sh [--words N] [--write] [--check] [--verbose] \
#       <test-name | path/to/source.(c|S|s)>
#
# Inputs:
#   tests/isa/<test-name>.S or tests/isa/<test-name>.c (or an explicit path)
#   tests/isa/<test-name>.sig  (optional; gives the word count and --check target)
#
# Outputs (under build/):
#   build/<name>.spike.{elf,text.hex,data.hex}  (Spike link, see link_spike.ld)
#   build/golden/<name>.sig                      (golden words, one per line)
#   build/golden/<name>.spike.{cmd,log}          (Spike debug commands / output)
#
# How it works:
#   1. Builds the program with build_prog.sh and LINKER_SCRIPT=link_spike.ld.
#      Spike reserves 0x0 for its debug module and boot ROM, so code moves to
#      0x8000_0000; DMEM and the signature window (0x2000_0100) do not move.
#      A signature word that holds a raw code/.rodata address therefore
#      differs by 0x8000_0000 (see docs/instruction_tests.md).
#   2. Runs Spike in debug mode for SPIKE_MAX_INSNS instructions, checks that
#      the PC is parked in the final self-loop, and reads the signature window.
#
# Environment variables:
#   SPIKE           : spike binary to use (default: spike)
#   SPIKE_ISA       : ISA string passed to spike (default: rv32i)
#   SPIKE_MAX_INSNS : instruction budget before the window is read (default: 1000000)
#   VERBOSE         : set to 1 to echo commands (or pass --verbose)
#   RISCV_GCC, RISCV_OBJCOPY, PYTHON, CFLAGS, LDFLAGS : passed to build_prog.sh
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/gen_golden.sh [--words N] [--write] [--check] [--verbose] <test-name | source>

Runs a test program on the Spike ISA simulator and writes the words of the
signature window (0x2000_0100) to build/golden/<name>.sig.

  --words N   number of signature words (default: line count of tests/isa/<name>.sig)
  --write     copy the result to tests/isa/<name>.sig
  --check     compare the result with tests/isa/<name>.sig (exit 1 on mismatch)
  --verbose   echo the underlying commands

Code is linked at 0x8000_0000 for Spike (link_spike.ld) instead of 0x0, so a
signature word that holds a raw code/.rodata address differs by 0x8000_0000.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v -- "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

# ------------------------------ Parse CLI flags ------------------------------

WORDS=""
DO_WRITE=0
DO_CHECK=0
VERBOSE=${VERBOSE:-0}

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    -n|--words)
      [[ $# -ge 2 ]] || die "--words needs a value"
      WORDS=$2
      shift
      ;;
    --words=*)
      WORDS=${1#--words=}
      ;;
    -w|--write)
      DO_WRITE=1
      ;;
    -c|--check)
      DO_CHECK=1
      ;;
    -v|--verbose)
      VERBOSE=1
      ;;
    *)
      args+=("$1")
      ;;
  esac
  shift
done

if [[ ${#args[@]} -ne 1 ]]; then
  usage
  exit 1
fi

# ----------------------------- Resolve paths ---------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
TEST_DIR="${REPO_ROOT}/tests/isa"

ARG=${args[0]}
if [[ -f "${ARG}" ]]; then
  # Explicit source path: the test name is the file name without extension.
  TEST_SRC=${ARG}
  TEST_NAME=$(basename -- "${ARG}")
  TEST_NAME=${TEST_NAME%.*}
elif [[ -f "${TEST_DIR}/${ARG}.S" ]]; then
  TEST_SRC="${TEST_DIR}/${ARG}.S"
  TEST_NAME=${ARG}
elif [[ -f "${TEST_DIR}/${ARG}.c" ]]; then
  TEST_SRC="${TEST_DIR}/${ARG}.c"
  TEST_NAME=${ARG}
else
  die "Test source not found: ${ARG} (looked for a file and tests/isa/${ARG}.S/.c)"
fi

EXPECTED="${TEST_DIR}/${TEST_NAME}.sig"

# Word count: --words, else the existing .sig file (one word per line).
# NOTE: `awk` instead of `grep -c` so that "0 matches" does not trip `set -e`.
if [[ -z "${WORDS}" ]]; then
  [[ -f "${EXPECTED}" ]] || die "No ${EXPECTED} to count words from; pass --words N"
  WORDS=$(awk 'NF { c++ } END { print c+0 }' "${EXPECTED}")
fi
[[ "${WORDS}" =~ ^[0-9]+$ ]] && (( WORDS > 0 )) || die "--words must be a positive integer (got: ${WORDS})"
if (( DO_CHECK )); then
  [[ -f "${EXPECTED}" ]] || die "--check needs an existing ${EXPECTED}"
fi

SPIKE=${SPIKE:-spike}
SPIKE_ISA=${SPIKE_ISA:-rv32i}
SPIKE_MAX_INSNS=${SPIKE_MAX_INSNS:-1000000}
require_cmd "${SPIKE}"

# Memory map seen by Spike: code at 0x8000_0000 (link_spike.ld), DMEM as on the core.
SIGNATURE_ADDR=$((0x20000100))
SPIKE_MEM="-m0x80000000:0x2000,0x20000000:0x2000"

BUILD_DIR="${REPO_ROOT}/build"
GOLDEN_DIR="${BUILD_DIR}/golden"
mkdir -p "${GOLDEN_DIR}"

ELF="${BUILD_DIR}/${TEST_NAME}.spike.elf"
CMD_FILE="${GOLDEN_DIR}/${TEST_NAME}.spike.cmd"
LOG_FILE="${GOLDEN_DIR}/${TEST_NAME}.spike.log"
OUT_SIG="${GOLDEN_DIR}/${TEST_NAME}.sig"

# ----------------------- Build the Spike ELF ---------------------------------

BUILD_PROG="${SCRIPT_DIR}/build_prog.sh"
[[ -x "${BUILD_PROG}" ]] || die "Missing or non-executable script: ${BUILD_PROG}"
LINKER_SCRIPT="${REPO_ROOT}/link_spike.ld" "${BUILD_PROG}" "${TEST_SRC}" "${TEST_NAME}.spike" >/dev/null

# ----------------------- Run Spike in debug mode -----------------------------
# rs N   : run N instructions silently (the test ends in a self-loop)
# pc 0   : print the PC of hart 0, twice around one more step; equal values
#          mean the program is parked in its final loop
# mem A  : print memory at physical address A (64-bit read when A is 8-aligned;
#          only the low 32 bits, the word at A, are kept)
{
  echo "rs ${SPIKE_MAX_INSNS}"
  echo "pc 0"
  echo "rs 1"
  echo "pc 0"
  for ((i = 0; i < WORDS; i++)); do
    printf 'mem 0x%x\n' $((SIGNATURE_ADDR + 4 * i))
  done
  echo "q"
} >"${CMD_FILE}"

spike_cmd=("${SPIKE}" -d --debug-cmd="${CMD_FILE}" --isa="${SPIKE_ISA}" "${SPIKE_MEM}" "${ELF}")
if [[ "${VERBOSE}" != 0 ]]; then
  echo "+ ${spike_cmd[*]}" >&2
fi
"${spike_cmd[@]}" >"${LOG_FILE}" 2>&1 || die "Spike failed; see ${LOG_FILE}"

# Spike prints each result as a 0x... value (plus a ": " prompt); keep the last
# 2 + WORDS of them (two PCs, then the signature words).
mapfile -t vals < <(grep -oE '0x[0-9a-fA-F]+' "${LOG_FILE}" | tail -n $((2 + WORDS)))
(( ${#vals[@]} == 2 + WORDS )) || die "Unexpected Spike output; see ${LOG_FILE}"

if (( vals[0] != vals[1] )); then
  die "Program did not reach its final self-loop within ${SPIKE_MAX_INSNS} instructions (PC ${vals[0]} -> ${vals[1]}); raise SPIKE_MAX_INSNS"
fi

: >"${OUT_SIG}"
for ((i = 0; i < WORDS; i++)); do
  printf '%08x\n' $(( vals[2 + i] & 0xffffffff )) >>"${OUT_SIG}"
done

echo "[SPIKE] ${TEST_NAME}: ${WORDS} signature words -> ${OUT_SIG}"
cat "${OUT_SIG}"

# ------------------------------ Check / write --------------------------------

status=0
if (( DO_CHECK )); then
  # Compare word by word, ignoring case and blank lines.
  if diff <(awk 'NF { print tolower($1) }' "${EXPECTED}") "${OUT_SIG}" >/dev/null; then
    echo "GOLDEN MATCH: ${EXPECTED}"
  else
    echo "GOLDEN MISMATCH: ${EXPECTED} (line: expected -> spike)" >&2
    paste -d' ' <(awk 'NF { print tolower($1) }' "${EXPECTED}") "${OUT_SIG}" \
      | awk '$1 != $2 { printf "  %d: %s -> %s\n", NR, $1, $2 }' >&2
    status=1
  fi
fi

if (( DO_WRITE )); then
  cp "${OUT_SIG}" "${EXPECTED}"
  echo "Wrote ${EXPECTED}"
fi

exit "${status}"
