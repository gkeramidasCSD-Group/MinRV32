#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# gen_schematic.sh - Generate SVG schematics from VHDL RTL using Yosys + GHDL.
#
# Toolchain:
#   VHDL  ->  ghdl (yosys-plugin-ghdl)  ->  Yosys synthesis  ->  JSON netlist
#         ->  netlistsvg  ->  SVG schematic
#
# Usage:
#   ./scripts/gen_schematic.sh <entity-name>           # one module
#   ./scripts/gen_schematic.sh --all                   # every RTL entity
#   ./scripts/gen_schematic.sh --list                  # list available entities
#
# Options:
#   --flat [N]          Flatten hierarchy (N = depth; omit N for full flatten)
#   --expand <entity>   Selectively expand specific sub-modules (repeatable)
#   --digitaljs         Also produce a DigitalJS-compatible JSON (interactive viewer)
#   --dot               Also generate a Graphviz DOT/PNG via Yosys `show` cmd
#   --keep-undef        Keep don't-care (x) mux inputs.  By default they are
#                       removed (opt_expr -mux_undef) so the schematic is not
#                       cluttered with floating stubs for unused encodings.
#   --mem-init <mod>=<hex>  Inject hex-file contents into the named module's
#                           $mem/$mem_v2 cell (repeatable).  Primarily useful
#                           with --digitaljs so the DigitalJS simulation starts
#                           with real firmware instead of all-zeros.
#                           <mod> is the VHDL entity name (e.g. imem_dp, dmem);
#                           <hex> is the path to a .text.hex or .data.hex file
#                           produced by build_prog.sh.
#   -o <dir>            Output directory (default: build/schematics)
#
# Examples:
#   ./scripts/gen_schematic.sh alu
#   ./scripts/gen_schematic.sh --flat riscvpipe                   # fully flat
#   ./scripts/gen_schematic.sh --flat 1 riscvpipe                 # 1 level
#   ./scripts/gen_schematic.sh --flat 2 datapath_pipe             # 2 levels
#   ./scripts/gen_schematic.sh --expand datapath_pipe riscvpipe   # selective
#   ./scripts/gen_schematic.sh --expand datapath_pipe --expand controller_pipe riscvpipe
#   ./scripts/gen_schematic.sh --all --dot
#   ./scripts/gen_schematic.sh --digitaljs \
#       --mem-init imem_dp=build/full_core.text.hex \
#       --mem-init dmem=build/full_core.data.hex \
#       top
#
# Outputs (under build/schematics/):
#   <entity>.json   Yosys JSON netlist
#   <entity>.svg    netlistsvg schematic
#   <entity>.dot    Graphviz DOT file         (with --dot)
#   <entity>.png    Graphviz rendered PNG     (with --dot)
#   <entity>.digitaljs.json  DigitalJS JSON   (with --digitaljs)
#
# Environment variables:
#   YOSYS       : yosys binary (default: yosys)
#   NETLISTSVG  : netlistsvg binary (default: netlistsvg)
#   GHDL_STD    : VHDL standard flag (default: --std=08)
#
# Requirements:
#   sudo apt install yosys ghdl yosys-plugin-ghdl graphviz
#   npm install -g netlistsvg             (or: sudo npm install -g netlistsvg)
#   npm install -g yosys2digitaljs        (optional, for --digitaljs)
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/gen_schematic.sh [options] <entity-name>
       ./scripts/gen_schematic.sh [options] --all
       ./scripts/gen_schematic.sh --list

Generate SVG schematics of RTL modules using Yosys (GHDL plugin) + netlistsvg.

Options:
  --flat [N]          Flatten hierarchy N levels deep (omit N for full flatten)
  --expand <entity>   Selectively expand only the named sub-modules (repeatable)
  --digitaljs         Also produce DigitalJS-compatible JSON (for interactive viewer)
  --dot               Also produce Graphviz DOT/PNG output
  --keep-undef        Keep don't-care (x) mux inputs (default: remove them so
                      the schematic has no floating stubs for unused encodings)
  --mem-init <mod>=<hex>  Inject hex-file contents into the named module's
                      $mem/$mem_v2 cell (repeatable; primarily for --digitaljs)
  --list              List all available RTL entity names and exit
  --all               Generate schematics for every RTL entity
  -o <dir>            Output directory (default: build/schematics)
  -h, --help          Show this help message
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v -- "$1" >/dev/null 2>&1 || die "Missing required command: $1 - $2"
}

# ----------------------------- Parse CLI flags --------------------------------
#
# Hierarchy control:
#   (default)          Hierarchical - sub-modules appear as labelled boxes.
#   --flat             Full flatten - expand every sub-module to primitives.
#   --flat N           Depth-limited - expand N levels, keep deeper modules
#                      as boxes.  E.g. --flat 1 expands only direct children.
#   --expand <entity>  Selective - expand only the named sub-module(s).
#                      Repeatable.  Everything else stays as boxes.
#
# --flat and --expand are mutually exclusive concepts but the script does not
# enforce this - if both are given, --expand takes priority.

FLAT_DEPTH=""          # empty = hierarchical, 0 = full flatten, N = N levels
EXPAND_LIST=()         # --expand targets: selectively flatten these sub-modules
GEN_DIGITALJS=false
GEN_DOT=false
GEN_ALL=false
KEEP_UNDEF=false       # true = keep don't-care mux inputs (skip opt_expr -mux_undef)
LIST_ONLY=false
OUT_DIR=""
ENTITIES=()
MEM_INIT_MAP=()        # --mem-init pairs: "module=hexfile" strings

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --flat)
      # Accept optional depth: --flat (full) or --flat N (N levels).
      if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
        FLAT_DEPTH=$2
        shift 2
      else
        FLAT_DEPTH=0
        shift
      fi
      ;;
    --expand)
      [[ -n "${2:-}" ]] || die "--expand requires an entity name"
      EXPAND_LIST+=("$2")
      shift 2
      ;;
    --digitaljs)
      GEN_DIGITALJS=true
      shift
      ;;
    --mem-init)
      [[ -n "${2:-}" ]] || die "--mem-init requires a module=hexfile argument"
      [[ "$2" == *=* ]] || die "--mem-init argument must be in module=hexfile form"
      MEM_INIT_MAP+=("$2")
      shift 2
      ;;
    --dot)
      GEN_DOT=true
      shift
      ;;
    --keep-undef)
      KEEP_UNDEF=true
      shift
      ;;
    --all)
      GEN_ALL=true
      shift
      ;;
    --list)
      LIST_ONLY=true
      shift
      ;;
    -o)
      [[ -n "${2:-}" ]] || die "-o requires a directory argument"
      OUT_DIR="$2"
      shift 2
      ;;
    -*)
      die "Unknown option: $1"
      ;;
    *)
      ENTITIES+=("$1")
      shift
      ;;
  esac
done

# ----------------------------- Resolve paths ----------------------------------

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

YOSYS=${YOSYS:-yosys}
NETLISTSVG=${NETLISTSVG:-netlistsvg}
GHDL_STD=${GHDL_STD:---std=08}

# Source shared helpers: VHDL file lists (glob-based) and entity discovery.
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vhdl_sources.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/vhdl_entities.sh"

# The yosys-ghdl plugin may have been compiled against a different GHDL backend
# than the one installed (e.g. it looks for `/usr/lib/ghdl/gcc/` while the
# system has the mcode backend at `/usr/lib/ghdl/mcode/`).  Auto-detect by
# asking the standalone `ghdl` where its libraries actually live.
if [[ -z "${GHDL_PREFIX:-}" ]]; then
  _detected_prefix=$(ghdl --disp-config 2>/dev/null \
    | grep -oP 'library prefix:\s*\K\S+' || true)
  if [[ -n "${_detected_prefix}" && -d "${_detected_prefix}" ]]; then
    export GHDL_PREFIX="${_detected_prefix}"
  fi
fi

require_cmd "${YOSYS}"      "install with: sudo apt install yosys"
require_cmd "${NETLISTSVG}" "install with: npm install -g netlistsvg"

if [[ "${GEN_DIGITALJS}" == true ]]; then
  # yosys2digitaljs is a Node.js library (no CLI binary).  Verify it is
  # importable from the global node_modules directory.
  NODE_PATH="$(npm root -g 2>/dev/null)" \
    node -e "require('yosys2digitaljs/core')" 2>/dev/null \
    || die "Cannot import yosys2digitaljs - install with: sudo npm install -g yosys2digitaljs"
fi

if [[ "${GEN_DOT}" == true ]]; then
  require_cmd dot "install with: sudo apt install graphviz"
fi

OUT_DIR=${OUT_DIR:-"${REPO_ROOT}/build/schematics"}
mkdir -p "${OUT_DIR}"

# ----------------------------- --list mode ------------------------------------

if [[ "${LIST_ONLY}" == true ]]; then
  echo "Available RTL entities (${#ALL_ENTITIES[@]}):"
  for e in "${ALL_ENTITIES[@]}"; do
    printf "  %-24s  %s\n" "${e}" "$(basename "${ENTITY_FILE_MAP[$e]}")"
  done
  exit 0
fi

# ----------------------------- Determine targets ------------------------------

if [[ "${GEN_ALL}" == true ]]; then
  ENTITIES=("${ALL_ENTITIES[@]}")
fi

if [[ ${#ENTITIES[@]} -eq 0 ]]; then
  usage
  exit 1
fi

# Validate --mem-init hex files exist before entering the per-entity loop.
for _pair in "${MEM_INIT_MAP[@]+"${MEM_INIT_MAP[@]}"}"; do
  _hex="${_pair#*=}"
  [[ -f "${_hex}" ]] || die "--mem-init: hex file not found: ${_hex}"
done
unset _pair _hex

# ----------------------------- Helper functions -------------------------------

# Build the Yosys synthesis script string for the given entity.
# Outputs the command string to stdout.
build_yosys_script() {
  local entity="$1"
  local json_file="${OUT_DIR}/${entity}.json"
  local yosys_cmds=""

  yosys_cmds+="ghdl ${GHDL_STD} ${VHDL_RTL_SOURCES[*]} -e ${entity}; "

  if [[ ${#EXPAND_LIST[@]} -gt 0 ]]; then
    # ---- Selective expand mode (--expand <entity> ...) ----
    # Strategy: mark ALL modules with keep_hierarchy, then un-mark only the
    # ones the user wants expanded.  `flatten` inlines un-marked modules
    # recursively, so --expand A --expand B works even if B is inside A.
    #
    # The `entity entity_*` pattern matches both plain VHDL names and
    # GHDL-mangled names (e.g. riscvpipe_bf8b4530... for generic entities).
    yosys_cmds+="prep -top ${entity}; "
    yosys_cmds+="setattr -mod -set keep_hierarchy 1 *; "
    for expand_ent in "${EXPAND_LIST[@]}"; do
      yosys_cmds+="setattr -mod -unset keep_hierarchy ${expand_ent} ${expand_ent}_*; "
    done
    yosys_cmds+="flatten; "
  elif [[ -z "${FLAT_DEPTH}" ]]; then
    # ---- Hierarchical mode (default) ----
    yosys_cmds+="prep -top ${entity}; "
  elif [[ "${FLAT_DEPTH}" -eq 0 ]]; then
    # ---- Full flatten mode (--flat) ----
    yosys_cmds+="prep -top ${entity} -flatten; "
  else
    # ---- Depth-limited flatten mode (--flat N) ----
    yosys_cmds+="prep -top ${entity}; "
    local -a keep_ents
    mapfile -t keep_ents < <(compute_keep_entities "${entity}" "${FLAT_DEPTH}")
    for keep_ent in "${keep_ents[@]}"; do
      yosys_cmds+="setattr -mod -set keep_hierarchy 1 ${keep_ent} ${keep_ent}_*; "
    done
    yosys_cmds+="flatten; "
  fi

  if [[ "${KEEP_UNDEF}" != true ]]; then
    # Remove don't-care (x) inputs from $mux/$pmux cells -- e.g. the default
    # branch of a result multiplexer for opcode encodings the design never
    # produces -- then sweep the now-dangling constant-x drivers.  netlistsvg
    # otherwise renders each undef bit as a floating stub, cluttering the
    # schematic with structures wired only to the mux default.  -mux_undef just
    # resolves don't-cares (synthesis is free to choose any value there), so the
    # defined behaviour of the design is unchanged.  --keep-undef opts out.
    yosys_cmds+="opt_expr -mux_undef; opt_clean; "
  fi

  yosys_cmds+="write_json ${json_file}; "

  if [[ "${GEN_DOT}" == true ]]; then
    yosys_cmds+="show -format dot -prefix ${OUT_DIR}/${entity} ${entity}; "
  fi

  echo "${yosys_cmds}"
}

# Run Yosys with the given command script.  Filters out harmless GHDL
# warnings (INIT_FILE attribute, ROM never-assigned notes, keep_hierarchy
# misses on mangled generic entity names, and the Xilinx clock primitives in
# fpga_top.vhd, which GHDL and Yosys treat as empty boxes).
# Returns non-zero on Yosys failure.
run_yosys() {
  local yosys_cmds="$1"
  local yosys_output

  if ! yosys_output=$("${YOSYS}" -m ghdl -q -p "${yosys_cmds}" 2>&1); then
    echo "${yosys_output}" >&2
    return 1
  fi
  if [[ -n "${yosys_output}" ]]; then
    echo "${yosys_output}" \
      | grep -E ':warning:|:error:|^ERROR:' \
      | grep -vE 'unhandled attribute "init_file"|signal "mem" is never assigned|Selection .* did not match any module|of component "(MMCME2_BASE|BUFG)" is not bound' \
      || true
  fi
}

# Post-process JSON labels and render to SVG via netlistsvg.
render_svg() {
  local entity="$1"
  local json_file="${OUT_DIR}/${entity}.json"
  local svg_file="${OUT_DIR}/${entity}.svg"

  if [[ ! -f "${json_file}" ]]; then
    echo "  [WARN] No JSON produced for '${entity}'" >&2
    return 1
  fi

  # Replace generic type labels (e.g. pipe_reg_32) with VHDL instance labels
  # (e.g. de_rs1_data_reg) so schematics are human-readable.  Demangling has
  # already been applied in generate_schematic, so only relabel is needed here.
  python3 "${SCRIPT_DIR}/netlist_labels.py" --relabel "${json_file}"

  # Large flattened designs can overflow Node's default call stack, so we
  # invoke netlistsvg via `node --stack-size=65536` (64 MB) to be safe.
  node --stack-size=65536 "$(command -v "${NETLISTSVG}")" \
    "${json_file}" -o "${svg_file}" 2>/dev/null
  echo "  [SVG]  ${svg_file}"
}

# Generate optional DigitalJS JSON and/or Graphviz DOT/PNG outputs.
render_optional_outputs() {
  local entity="$1"
  local json_file="${OUT_DIR}/${entity}.json"

  if [[ "${GEN_DIGITALJS}" == true && -f "${json_file}" ]]; then
    local djs_file="${OUT_DIR}/${entity}.digitaljs.json"
    # io_ui() remaps raw Input/Output ports to simulator UI widgets:
    #   1-bit Input named clk/clock -> Clock device (self-ticking, propagation=100)
    #   other 1-bit Input          -> Button (one-click pulse; good for reset)
    #   multi-bit Input            -> NumEntry (typeable number field)
    #   1-bit Output               -> Lamp
    #   multi-bit Output           -> NumDisplay
    # Without this call, every input stays as a raw toggle requiring manual
    # clicks for each value change (including the clock on every cycle).
    NODE_PATH="$(npm root -g 2>/dev/null)" node -e "
      const fs = require('fs');
      const { yosys2digitaljs, io_ui } = require('yosys2digitaljs/core');
      const src = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
      const output = yosys2digitaljs(src);
      io_ui(output);
      fs.writeFileSync(process.argv[2], JSON.stringify(output));
    " "${json_file}" "${djs_file}" 2>/dev/null
    echo "  [DJS]  ${djs_file}"
  fi

  if [[ "${GEN_DOT}" == true ]]; then
    local dot_file="${OUT_DIR}/${entity}.dot"
    local png_file="${OUT_DIR}/${entity}.png"
    if [[ -f "${dot_file}" ]]; then
      dot -Tpng "${dot_file}" -o "${png_file}" 2>/dev/null
      echo "  [PNG]  ${png_file}"
    fi
  fi
}

# ----------------------------- Generate schematics ----------------------------

generate_schematic() {
  local entity="$1"

  if [[ -z "${ENTITY_FILE_MAP[$entity]+x}" ]]; then
    echo "warning: unknown entity '${entity}' - skipping" >&2
    return 1
  fi

  echo "==> ${entity}"

  local yosys_cmds
  yosys_cmds=$(build_yosys_script "${entity}")

  if ! run_yosys "${yosys_cmds}"; then
    echo "  [FAIL] Yosys elaboration failed for '${entity}'" >&2
    return 1
  fi

  # Strip GHDL generic-hash suffixes (e.g. hazard_unit_bf8b4530 -> hazard_unit)
  # so all downstream outputs get clean names.  This pass is safe to run before
  # yosys2digitaljs because it only renames modules (no duplication).
  python3 "${SCRIPT_DIR}/netlist_labels.py" --demangle "${OUT_DIR}/${entity}.json"

  # Inject memory initial values from hex files into $mem/$mem_v2 cells.
  # Yosys/GHDL synthesis strips the init_mem() file I/O that lives inside
  # "synthesis translate_off" guards in mem_init_pkg.vhd, so every memory
  # cell would otherwise start as all-zeros in the DigitalJS simulation.
  # This step patches the INIT parameter with real firmware content.
  if [[ ${#MEM_INIT_MAP[@]} -gt 0 ]]; then
    local inject_args=()
    for pair in "${MEM_INIT_MAP[@]}"; do
      inject_args+=(--module "${pair%%=*}" --hex "${pair#*=}")
    done
    python3 "${SCRIPT_DIR}/mem_init_inject.py" \
      --json "${OUT_DIR}/${entity}.json" \
      "${inject_args[@]}"
  fi

  # DigitalJS conversion must run BEFORE the relabel pass, because relabel
  # duplicates modules in the JSON, which breaks yosys2digitaljs's
  # topological-sort top-module detection.
  render_optional_outputs "${entity}"
  render_svg "${entity}" || return 1
}

# ----------------------------- Main loop --------------------------------------

passed=0
failed=0

for entity in "${ENTITIES[@]}"; do
  if generate_schematic "${entity}"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo ""
echo "Done: ${passed} generated, ${failed} failed.  Output: ${OUT_DIR}/"
if [[ ${failed} -gt 0 ]]; then
  exit 1
fi
