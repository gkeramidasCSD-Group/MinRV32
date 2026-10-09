#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# build_prog.sh - Build a freestanding RV32I program into IMEM/DMEM hex images.
#
# Usage:
#   ./scripts/build_prog.sh <source.(c|S|s)> [output_base]
#
# Outputs (under build/):
#   <output_base>.elf
#   <output_base>.text.hex  (for instruction memory: .text/.rodata)
#   <output_base>.data.hex  (for data memory: .data/.sdata; .bss is zeroed)
#   <output_base>.S         (only when compiling a .c source; GCC assembly)
#
# Environment variables:
#   RISCV_GCC     : C compiler to use (default: riscv64-unknown-elf-gcc)
#   RISCV_OBJCOPY : objcopy to use (default: riscv64-unknown-elf-objcopy)
#   PYTHON        : Python interpreter (default: python3)
#   CFLAGS        : override default CFLAGS (whitespace-split into argv)
#   LDFLAGS       : override default LDFLAGS (whitespace-split into argv)
#   IMEM_BYTES    : IMEM size in bytes for size warnings (default: 8192)
#   DMEM_BYTES    : DMEM size in bytes for size warnings (default: 8192)
#   LINKER_SCRIPT : linker script to use (default: link.ld; gen_golden.sh
#                   passes link_spike.ld)
#
# Notes:
# - Defaults are intentionally "bare-metal friendly" (no libc, no OS).
# - The linker script `link.ld` maps .text to IMEM at 0x0000_0000 and .data/.bss
#   to DMEM at 0x2000_0000 (see docs/memory_map.md).
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/build_prog.sh <source.(c|S|s)> [output_base]

Compiles and links a small bare-metal RV32I program for this repository's
memory map, then extracts `.text/.rodata` and `.data/.sdata` into hex files
consumable by the VHDL memories.
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v -- "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SRC=$1
NAME=${2:-prog}
SRC_EXT=${SRC##*.}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
BUILD_DIR="${REPO_ROOT}/build"
LDSCRIPT="${LINKER_SCRIPT:-${REPO_ROOT}/link.ld}"

# ----------------------------- Resolve toolchain -----------------------------

RISCV_GCC=${RISCV_GCC:-riscv64-unknown-elf-gcc}
RISCV_OBJCOPY=${RISCV_OBJCOPY:-riscv64-unknown-elf-objcopy}
PYTHON=${PYTHON:-python3}

require_cmd "${RISCV_GCC}"
require_cmd "${RISCV_OBJCOPY}"
require_cmd "${PYTHON}"

[[ -f "${SRC}" ]] || die "Source file not found: ${SRC}"
[[ -f "${LDSCRIPT}" ]] || die "Linker script not found: ${LDSCRIPT}"

# ---------------------- Default compiler / linker flags -----------------------
# These are bare-metal-friendly defaults: no libc, no PIC, RV32I only.

DEFAULT_CFLAGS=(
  -march=rv32i
  -mabi=ilp32
  -Os
  -ffreestanding
  -nostdlib
  -fno-builtin
  -fno-pic
  -mcmodel=medlow
  -fno-asynchronous-unwind-tables
  -fno-stack-protector
)
DEFAULT_LDFLAGS=(
  -nostdlib
  -Wl,-e,_start
  -Wl,--gc-sections
  # Some toolchains (for example the RISC-V GCC that comes with AMD Vitis) add
  # a build-ID note section by default. The linker scripts discard it; this
  # flag stops the linker from creating it, so it does not warn.
  -Wl,--build-id=none
)

# Allow env overrides (CFLAGS / LDFLAGS) while keeping argv handling sane.
# When the env var is set, it is word-split into an array; otherwise the
# defaults defined above are used.
CFLAGS_ARR=()
LDFLAGS_ARR=()
if [[ -n "${CFLAGS:-}" ]]; then
  read -r -a CFLAGS_ARR <<<"${CFLAGS}"
else
  CFLAGS_ARR=("${DEFAULT_CFLAGS[@]}")
fi
if [[ -n "${LDFLAGS:-}" ]]; then
  read -r -a LDFLAGS_ARR <<<"${LDFLAGS}"
else
  LDFLAGS_ARR=("${DEFAULT_LDFLAGS[@]}")
fi

# ----------------------------- Output file paths -----------------------------

mkdir -p "${BUILD_DIR}"

ELF="${BUILD_DIR}/${NAME}.elf"
TEXT_BIN="${BUILD_DIR}/${NAME}.text.bin"
DATA_BIN="${BUILD_DIR}/${NAME}.data.bin"
TEXT_HEX="${BUILD_DIR}/${NAME}.text.hex"
DATA_HEX="${BUILD_DIR}/${NAME}.data.hex"

# ----------------------------- Compile / Link --------------------------------

# ASM_NOTE collects an extra line for the summary when a .c source also
# produces a GCC-generated assembly listing (.S).
ASM_NOTE=""
if [[ "${SRC_EXT,,}" == "c" ]]; then
  ASM_OUT="${BUILD_DIR}/${NAME}.S"
  echo "[GCC] ${SRC} -> ${ASM_OUT}"
  "${RISCV_GCC}" "${CFLAGS_ARR[@]}" -S "${SRC}" -o "${ASM_OUT}"
  ASM_NOTE="  - ${NAME}.S          : GCC-generated assembly from the C source
"
fi

echo "[GCC] ${SRC} -> ${ELF}"
"${RISCV_GCC}" "${CFLAGS_ARR[@]}" "${LDFLAGS_ARR[@]}" -T "${LDSCRIPT}" "${SRC}" -o "${ELF}"

# -------------------------- Extract binary sections --------------------------

echo "[OBJCOPY] extracting .text/.rodata"
"${RISCV_OBJCOPY}" -O binary -j .text -j .text.* -j .rodata -j .rodata.* "${ELF}" "${TEXT_BIN}"

# Extract .data/.sdata into a flat binary. If the ELF has no such sections,
# objcopy may fail or produce an empty file - in either case we create an
# empty DATA_BIN so downstream steps always have a valid (possibly zero-size)
# input file.
echo "[OBJCOPY] extracting .data/.sdata"
if ! "${RISCV_OBJCOPY}" -O binary -j .data -j .data.* -j .sdata -j .sdata.* "${ELF}" "${DATA_BIN}" 2>/dev/null \
   || [[ ! -s "${DATA_BIN}" ]]; then
  : > "${DATA_BIN}"
fi

# ----------------------- Convert binary -> hex words -------------------------

echo "[HEX] ${TEXT_BIN} -> ${TEXT_HEX}"
"${PYTHON}" "${SCRIPT_DIR}/bin_to_hex.py" --input "${TEXT_BIN}" --output "${TEXT_HEX}"

echo "[HEX] ${DATA_BIN} -> ${DATA_HEX}"
"${PYTHON}" "${SCRIPT_DIR}/bin_to_hex.py" --input "${DATA_BIN}" --output "${DATA_HEX}"

# ------------------------------ Size summary ---------------------------------
# Helpful size summary for the default 8 KiB IMEM / 8 KiB DMEM configuration.
# (See docs/memory_map.md for the rationale and address layout.)
TEXT_WORDS=$(wc -l <"${TEXT_HEX}" | tr -d ' ')
DATA_WORDS=$(wc -l <"${DATA_HEX}" | tr -d ' ')
TEXT_BYTES=$((TEXT_WORDS * 4))
DATA_BYTES=$((DATA_WORDS * 4))
IMEM_BYTES=${IMEM_BYTES:-8192}
DMEM_BYTES=${DMEM_BYTES:-8192}

cat <<EOF

Artifacts written to ${BUILD_DIR}:
  - ${NAME}.elf       : full ELF
  - ${NAME}.text.hex  : load into instruction memory (text/rodata)
  - ${NAME}.data.hex  : load into data memory (.data, zero-extend for .bss)
${ASM_NOTE}
Sizes:
  - text/rodata: ${TEXT_BYTES} bytes (${TEXT_WORDS} words)  [IMEM capacity: ${IMEM_BYTES} bytes]
  - data/sdata : ${DATA_BYTES} bytes (${DATA_WORDS} words)  [DMEM capacity: ${DMEM_BYTES} bytes]

EOF

if (( TEXT_BYTES > IMEM_BYTES )); then
  echo "warning: .text/.rodata image exceeds IMEM capacity (${TEXT_BYTES} > ${IMEM_BYTES} bytes)" >&2
fi
if (( DATA_BYTES > DMEM_BYTES )); then
  echo "warning: .data/.sdata image exceeds DMEM capacity (${DATA_BYTES} > ${DMEM_BYTES} bytes)" >&2
fi
