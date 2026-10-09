#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# clean.sh - Remove generated build/simulation artifacts from the repository.
#
# Usage:
#   ./scripts/clean.sh
#
# Removes:
# - build/                 (all script outputs, including waveforms and GHDL workdirs)
# - tmp/                   (if present)
# - scripts/__pycache__/
# - work-obj*.cf           (GHDL work library index files created in repo root)
# - e~*                    (GHDL elaboration executables created in repo root)
# - .Xil/                  (Vivado temp/cache directory created in repo root)
# - vivado*                (Vivado journal/log files: vivado.jou, vivado.log,
#                           vivado_<pid>.backup.jou, etc.)
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/clean.sh

Deletes build outputs and simulator artifacts so you can start from a clean tree.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "${arg}" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: ${arg}"
      ;;
  esac
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# Fixed artifact paths to always remove.
ARTIFACTS=(
  "${REPO_ROOT}/build"
  "${REPO_ROOT}/tmp"
  "${REPO_ROOT}/scripts/__pycache__"
  "${REPO_ROOT}/.Xil"
)

# Dynamically discover GHDL work-library index files (work-obj*.cf) and
# elaboration executables (e~*) that may have been created in the repo root.
shopt -s nullglob
for cf in "${REPO_ROOT}"/work-obj*.cf; do
  ARTIFACTS+=("${cf}")
done
# Include GHDL elaboration executables (e.g., e~tb_minrv32).
for elab in "${REPO_ROOT}"/e~*; do
  ARTIFACTS+=("${elab}")
done
# Include Vivado journal/log files (vivado.jou, vivado.log, and backup variants
# like vivado_<pid>.backup.jou) that Vivado drops in the directory it was
# launched from.
for vjunk in "${REPO_ROOT}"/vivado*; do
  ARTIFACTS+=("${vjunk}")
done
shopt -u nullglob

# Remove every collected artifact and report what was deleted.
removed_any=false

for target in "${ARTIFACTS[@]}"; do
  if [[ -e "${target}" ]]; then
    rm -rf -- "${target}"
    echo "Removed ${target}"
    removed_any=true
  fi
done

if [[ "${removed_any}" = false ]]; then
  echo "Nothing to clean."
fi
