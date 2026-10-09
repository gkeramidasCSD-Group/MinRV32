#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# run_tests.sh - Batch driver for ISA tests under tests/isa/.
#
# Usage:
#   ./scripts/run_tests.sh [--trace] [--verbose]
#
# Discovers every tests/isa/*.sig file, derives the test name, and invokes
# scripts/run_test.sh for each one. Prints a pass/fail summary at the end.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/run_tests.sh [--trace] [--verbose]

Runs every ISA test that has a corresponding .sig file in tests/isa/.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="${REPO_ROOT}/tests/isa"
TRACE_FLAG=""
VERBOSE_FLAG=""

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    -t|--trace)
      TRACE_FLAG="--trace"
      ;;
    -v|--verbose)
      VERBOSE_FLAG="--verbose"
      ;;
    *)
      die "Unknown argument: ${arg}"
      ;;
  esac
done

RUN_TEST="${REPO_ROOT}/scripts/run_test.sh"
[[ -x "${RUN_TEST}" ]] || die "Missing or non-executable script: ${RUN_TEST}"

# Discover every .sig file and derive the test name (filename without .sig).
shopt -s nullglob
sig_files=( "${TEST_DIR}"/*.sig )
shopt -u nullglob

if [[ ${#sig_files[@]} -eq 0 ]]; then
  echo "No tests found in ${TEST_DIR}" >&2
  exit 1
fi

tests=()
for sig in "${sig_files[@]}"; do
  tests+=( "$(basename "${sig}" .sig)" )
done

# Sort test names alphabetically for deterministic, reproducible ordering.
mapfile -t tests < <(printf '%s\n' "${tests[@]}" | sort)

passed=0
failed=0
fail_list=()

for t in "${tests[@]}"; do
  echo "===> Running ${t}"
  # TRACE_FLAG / VERBOSE_FLAG are intentionally unquoted so that an empty
  # string expands to nothing (no extra empty argument passed to the script).
  if "${RUN_TEST}" ${TRACE_FLAG} ${VERBOSE_FLAG} "${t}"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    fail_list+=("${t}")
    echo "FAIL: ${t}" >&2
  fi
done

echo ""
echo "Results: ${passed} passed, ${failed} failed out of ${#tests[@]} tests."
if [[ ${failed} -gt 0 ]]; then
  echo "Failed tests:" >&2
  for f in "${fail_list[@]}"; do
    echo "  - ${f}" >&2
  done
  exit 1
fi
