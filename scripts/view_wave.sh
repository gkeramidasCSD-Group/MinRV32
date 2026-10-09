#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# view_wave.sh - Convenience wrapper to open a waveform in GTKWave.
#
# Usage:
#   ./scripts/view_wave.sh <wave-file.(fst|vcd|ghw)>
#
# Example:
#   ./scripts/view_wave.sh build/waves/tb_regfile.fst
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/view_wave.sh <wave-file.(fst|vcd|ghw)>

Opens the given waveform file in GTKWave (if installed).
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

if [[ ${#} -ne 1 ]]; then
  usage
  exit 1
fi
if [[ "${1}" == "-h" ]] || [[ "${1}" == "--help" ]]; then
  usage
  exit 0
fi

WAVE_FILE=$1
if [[ ! -f "${WAVE_FILE}" ]]; then
  die "Wave file not found: ${WAVE_FILE}"
fi

# Warn (but don't refuse) if the extension isn't one of the common waveform
# formats recognised by GTKWave.
case "${WAVE_FILE##*.}" in
  fst|vcd|ghw|lxt|lxt2) ;;
  *) echo "warning: unexpected file extension '${WAVE_FILE##*.}' - GTKWave may not recognise it" >&2 ;;
esac

# Use `exec` to replace this shell process with GTKWave, avoiding an extra
# process layer.
if command -v gtkwave >/dev/null 2>&1; then
  exec gtkwave "${WAVE_FILE}"
fi

echo "gtkwave is not installed." >&2
echo "Install it (Ubuntu/Debian): sudo apt install gtkwave" >&2
exit 2
