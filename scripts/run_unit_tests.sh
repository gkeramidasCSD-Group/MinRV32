#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run_unit_tests.sh - Batch driver for unit-level VHDL testbenches (sim/unit/).
#
# Usage:
#   ./scripts/run_unit_tests.sh [--wave|--vcd|--fst] [--verbose]
#
# Discovers every sim/unit/tb_*.vhd file, derives the testbench name, and
# invokes scripts/run_unit_tb.sh for each one. Prints a pass/fail summary at
# the end.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/run_unit_tests.sh [--wave|--vcd|--fst] [--verbose]

Runs every unit-level self-checking VHDL testbench found under sim/unit/.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
UNIT_DIR="${REPO_ROOT}/sim/unit"
WAVE_FLAG=""
VERBOSE_FLAG=""

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    --wave|--vcd|--fst)
      WAVE_FLAG="${arg}"
      ;;
    -v|--verbose)
      VERBOSE_FLAG="--verbose"
      ;;
    *)
      die "Unknown argument: ${arg}"
      ;;
  esac
done

RUN_UNIT_TB="${REPO_ROOT}/scripts/run_unit_tb.sh"
[[ -x "${RUN_UNIT_TB}" ]] || die "Missing or non-executable script: ${RUN_UNIT_TB}"

# Discover every sim/unit/tb_*.vhd file and collect the testbench entity names.
shopt -s nullglob
tb_files=( "${UNIT_DIR}"/tb_*.vhd )
shopt -u nullglob

if [[ ${#tb_files[@]} -eq 0 ]]; then
  echo "No unit testbenches found in ${UNIT_DIR}" >&2
  exit 1
fi

tbs=()
for tb in "${tb_files[@]}"; do
  tbs+=( "$(basename "${tb}" .vhd)" )
done

# Sort testbench names alphabetically for deterministic, reproducible ordering.
mapfile -t tbs < <(printf '%s\n' "${tbs[@]}" | sort)

passed=0
failed=0
fail_list=()

for tb in "${tbs[@]}"; do
  echo "===> Running ${tb}"
  # WAVE_FLAG / VERBOSE_FLAG are intentionally unquoted so that an empty
  # string expands to nothing (no extra empty argument passed to the script).
  if "${RUN_UNIT_TB}" ${WAVE_FLAG} ${VERBOSE_FLAG} "${tb}"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    fail_list+=("${tb}")
    echo "FAIL: ${tb}" >&2
  fi
done

echo ""
echo "Results: ${passed} passed, ${failed} failed out of ${#tbs[@]} testbenches."
if [[ ${failed} -gt 0 ]]; then
  echo "Failed testbenches:" >&2
  for tb in "${fail_list[@]}"; do
    echo "  - ${tb}" >&2
  done
  exit 1
fi
