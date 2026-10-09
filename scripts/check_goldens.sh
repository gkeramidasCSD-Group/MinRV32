#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# check_goldens.sh - Check every golden signature under tests/isa/ against Spike.
#
# Usage:
#   ./scripts/check_goldens.sh [--verbose]
#
# Discovers every tests/isa/*.sig file, derives the test name, and invokes
# scripts/gen_golden.sh --check for each one. Prints a pass/fail summary at
# the end. Needs the Spike ISA simulator (see docs/instruction_tests.md).
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/check_goldens.sh [--verbose]

Re-generates the signature of every test that has a .sig file in tests/isa/
with Spike and compares it with the checked-in .sig file.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR="${REPO_ROOT}/tests/isa"
VERBOSE_FLAG=""

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    -v|--verbose)
      VERBOSE_FLAG="--verbose"
      ;;
    *)
      die "Unknown argument: ${arg}"
      ;;
  esac
done

GEN_GOLDEN="${REPO_ROOT}/scripts/gen_golden.sh"
[[ -x "${GEN_GOLDEN}" ]] || die "Missing or non-executable script: ${GEN_GOLDEN}"

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
mapfile -t tests < <(printf '%s\n' "${tests[@]}" | sort)

passed=0
failed=0
fail_list=()

for t in "${tests[@]}"; do
  echo "===> Checking ${t}"
  # VERBOSE_FLAG is intentionally unquoted so an empty string adds no argument.
  if "${GEN_GOLDEN}" --check ${VERBOSE_FLAG} "${t}"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    fail_list+=("${t}")
    echo "FAIL: ${t}" >&2
  fi
done

echo ""
echo "Results: ${passed} match, ${failed} differ out of ${#tests[@]} golden files."
if [[ ${failed} -gt 0 ]]; then
  echo "Differing tests:" >&2
  for f in "${fail_list[@]}"; do
    echo "  - ${f}" >&2
  done
  exit 1
fi
