#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# health_check.sh - Run every step of the MinRV32 flow and report pass/fail.
#
# Usage:
#   ./scripts/health_check.sh [options]
#
# The script copies the repository (tracked files plus untracked files that
# are not ignored by git) into a new output directory and runs every step in
# that copy, so the working tree is never changed. By default it starts the
# run in the background, detached from the terminal (setsid + nohup), prints
# where the log is, and returns. The run keeps going after the terminal is
# closed. Use --foreground to run it in the current terminal instead.
#
# Steps, in run order:
#   build        build_prog.sh on every tests/isa/*.c and *.S file
#   unit         run_unit_tests.sh (every unit testbench in sim/unit/)
#   waves        run_unit_tb.sh --fst alu and run_test.sh --fst addi_only,
#                then check that both .fst files were written
#   isa          run_tests.sh (every test that has a .sig file)
#   trace        run_test.sh --trace addi_only, then check the trace output
#   stall        run_tests.sh with FORWARDING_ENABLE=false
#   golden       check_goldens.sh (Spike signatures against tests/isa/*.sig)
#   schematic    gen_schematic.sh --all (SVG schematic of every RTL entity)
#   digitaljs    gen_schematic.sh --digitaljs for alu, and for top with the
#                full_core program loaded by --mem-init
#   vivado-sim   vivado_project.tcl for the first board, then an XSim
#                simulation that must print "TEST PASSED"
#   vivado-impl  for every board: vivado_project.tcl, synthesis, a check that
#                MARK_DEBUG nets and block RAMs are present, implementation,
#                bitstream, and a check that setup timing is met. It also
#                prints the core clock and an estimate of the highest core
#                clock frequency that would still meet timing.
#   latex        make -C latex pdf (builds the project manual)
#   clean        clean.sh, then a check that build/ was removed. This step
#                is skipped when an earlier step failed, so the build files
#                stay available for debugging.
#
# A step whose tools are not installed is reported as SKIP, not FAIL.
# Not covered: view_wave.sh (opens a GUI window), and programming a board and
# capturing the signature with the ILA (needs a connected board).
#
# Options:
#   --foreground        Run in this terminal instead of in the background.
#   --out <dir>         Output directory (default: build/health/<date-time>).
#   --only <list>       Run only these steps (comma-separated step names).
#   --skip <list>       Do not run these steps (comma-separated step names).
#   --boards <list>     Boards for the Vivado steps (default: basys3,zedboard).
#   --vivado-test <t>   Program used by the Vivado steps (default: full_core).
#   --clk-mhz <f>       Core clock in MHz for the Vivado steps, passed to
#                       vivado_project.tcl (default: the board's default).
#   --jobs <n>          Parallel jobs for Vivado runs (default: 4).
#   --xilinx-dir <dir>  Xilinx install directory. The script uses the newest
#                       <dir>/Vivado/<version>/settings64.sh. <dir> can also be
#                       a directory that holds settings64.sh directly.
#   --path <dir>        Add <dir> to the front of PATH (repeatable). Use it for
#                       tools that are not on PATH, such as the RISC-V GCC or
#                       Spike.
#   --strict            Exit with code 1 when any step was skipped.
#
# Output directory contents:
#   health.log          Full log of the run (follow it with tail -f)
#   summary.txt         One line per step with its result
#   status              PASS, FAIL or RUNNING
#   pid                 Process ID of a background run
#   logs/<NN>_<step>.log  Output of each step
#   reports/<board>/    Vivado utilization and timing reports, and bitstream
#   repo/               The copy of the repository that the steps ran in
#
# Environment variables:
#   XILINX_DIR          Same as --xilinx-dir.
#   GHDL, RISCV_GCC, RISCV_OBJCOPY, SPIKE, YOSYS, NETLISTSVG are passed on to
#   the scripts that use them and are also used to check that the tools exist.
#
# Exit status: 0 when no step failed, 1 otherwise. In the background mode the
# exit status only reports whether the run was started; read <out>/status.
# -----------------------------------------------------------------------------

usage() {
  cat <<'EOF' >&2
Usage: ./scripts/health_check.sh [--foreground] [--out <dir>] [--only <list>]
                                 [--skip <list>] [--boards <list>]
                                 [--vivado-test <name>] [--clk-mhz <f>] [--jobs <n>]
                                 [--xilinx-dir <dir>] [--path <dir>]... [--strict]

Copies the repository into <out>/repo and runs every step of the flow there
(unit testbenches, ISA tests, Spike goldens, schematics, Vivado simulation and
implementation, LaTeX manual, clean). Runs in the background by default.

Steps: build unit waves isa trace stall golden schematic digitaljs
       vivado-sim vivado-impl latex clean

Example:
  ./scripts/health_check.sh --xilinx-dir /tools/Xilinx \
      --path /opt/riscv/bin --path /opt/spike/bin
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

ALL_STEPS=(build unit waves isa trace stall golden schematic digitaljs
           vivado-sim vivado-impl latex clean)

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# ------------------------------ Parse CLI flags ------------------------------

FOREGROUND=false
WORKER=false
STRICT=false
OUT_DIR=""
ONLY_LIST=""
SKIP_LIST=""
BOARDS_LIST="basys3,zedboard"
VIVADO_TEST="full_core"
CLK_MHZ=""
JOBS=4
XILINX_DIR=${XILINX_DIR:-}
EXTRA_PATHS=()

need_value() {
  [[ $# -ge 2 && -n "$2" ]] || die "Option $1 needs a value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --foreground)  FOREGROUND=true; shift ;;
    --worker)      WORKER=true; shift ;;   # internal: run the steps
    --strict)      STRICT=true; shift ;;
    --out)         need_value "$@"; OUT_DIR=$2; shift 2 ;;
    --only)        need_value "$@"; ONLY_LIST=$2; shift 2 ;;
    --skip)        need_value "$@"; SKIP_LIST=$2; shift 2 ;;
    --boards)      need_value "$@"; BOARDS_LIST=$2; shift 2 ;;
    --vivado-test) need_value "$@"; VIVADO_TEST=$2; shift 2 ;;
    --clk-mhz)     need_value "$@"; CLK_MHZ=$2; shift 2 ;;
    --jobs)        need_value "$@"; JOBS=$2; shift 2 ;;
    --xilinx-dir)  need_value "$@"; XILINX_DIR=$2; shift 2 ;;
    --path)        need_value "$@"; EXTRA_PATHS+=("$2"); shift 2 ;;
    *)             die "Unknown argument: $1" ;;
  esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "--jobs needs a positive number"

# Check that every name in a comma-separated list is a known step.
check_step_list() {
  local list=$1 name known
  IFS=',' read -r -a names <<< "${list}"
  for name in "${names[@]}"; do
    known=false
    for s in "${ALL_STEPS[@]}"; do
      [[ "${s}" == "${name}" ]] && known=true
    done
    [[ "${known}" == true ]] || die "Unknown step: ${name} (steps: ${ALL_STEPS[*]})"
  done
}
[[ -n "${ONLY_LIST}" ]] && check_step_list "${ONLY_LIST}"
[[ -n "${SKIP_LIST}" ]] && check_step_list "${SKIP_LIST}"

IFS=',' read -r -a BOARDS <<< "${BOARDS_LIST}"
[[ ${#BOARDS[@]} -gt 0 ]] || die "--boards needs at least one board"

for p in "${EXTRA_PATHS[@]}"; do
  [[ -d "${p}" ]] || die "--path directory not found: ${p}"
  PATH="$(cd -- "${p}" && pwd):${PATH}"
done
export PATH

# Find the Vivado settings script. Empty when Vivado is not available this way.
VIVADO_SETTINGS=""
if [[ -n "${XILINX_DIR}" ]]; then
  [[ -d "${XILINX_DIR}" ]] || die "--xilinx-dir directory not found: ${XILINX_DIR}"
  XILINX_DIR=$(cd -- "${XILINX_DIR}" && pwd)
  if [[ -f "${XILINX_DIR}/settings64.sh" ]]; then
    VIVADO_SETTINGS="${XILINX_DIR}/settings64.sh"
  else
    VIVADO_SETTINGS=$(ls -d "${XILINX_DIR}"/Vivado/*/settings64.sh 2>/dev/null \
                      | sort -V | tail -n 1 || true)
    [[ -n "${VIVADO_SETTINGS}" ]] \
      || die "No Vivado/<version>/settings64.sh found under ${XILINX_DIR}"
  fi
fi

# ============================================================================
# Launcher: copy the repository and start the worker.
# ============================================================================

if [[ "${WORKER}" == false ]]; then
  # Collect the file list before creating the output directory, so that the
  # output directory is never part of the copy.
  files=()
  source_desc="${REPO_ROOT} (not a git repository)"
  if git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r -d '' f; do
      # Skip tracked files that were deleted in the working tree.
      [[ -e "${REPO_ROOT}/${f}" || -L "${REPO_ROOT}/${f}" ]] && files+=("${f}")
    done < <(git -C "${REPO_ROOT}" ls-files -z --cached --others --exclude-standard)
    commit=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "none")
    changes=$(git -C "${REPO_ROOT}" status --porcelain | wc -l)
    source_desc="${REPO_ROOT} (commit ${commit}, ${changes} changed or untracked files)"
  fi

  if [[ -z "${OUT_DIR}" ]]; then
    OUT_DIR="${REPO_ROOT}/build/health/$(date +%Y%m%d-%H%M%S)"
  fi
  [[ -e "${OUT_DIR}" ]] && die "Output directory already exists: ${OUT_DIR}"
  mkdir -p "${OUT_DIR}/repo"
  OUT_DIR=$(cd -- "${OUT_DIR}" && pwd)

  if [[ ${#files[@]} -gt 0 ]]; then
    printf '%s\0' "${files[@]}" \
      | tar -C "${REPO_ROOT}" --null -T - -cf - \
      | tar -C "${OUT_DIR}/repo" -xf -
  else
    tar -C "${REPO_ROOT}" --exclude=./build -cf - . | tar -C "${OUT_DIR}/repo" -xf -
  fi
  echo "${source_desc}" > "${OUT_DIR}/source.txt"
  echo "RUNNING" > "${OUT_DIR}/status"

  worker_args=(--worker --out "${OUT_DIR}" --boards "${BOARDS_LIST}"
               --vivado-test "${VIVADO_TEST}" --jobs "${JOBS}")
  [[ -n "${ONLY_LIST}" ]] && worker_args+=(--only "${ONLY_LIST}")
  [[ -n "${SKIP_LIST}" ]] && worker_args+=(--skip "${SKIP_LIST}")
  [[ -n "${XILINX_DIR}" ]] && worker_args+=(--xilinx-dir "${XILINX_DIR}")
  [[ -n "${CLK_MHZ}" ]] && worker_args+=(--clk-mhz "${CLK_MHZ}")
  [[ "${STRICT}" == true ]] && worker_args+=(--strict)
  worker=("${BASH}" "${OUT_DIR}/repo/scripts/health_check.sh" "${worker_args[@]}")

  if [[ "${FOREGROUND}" == true ]]; then
    set +e
    "${worker[@]}" < /dev/null 2>&1 | tee "${OUT_DIR}/health.log"
    rc=${PIPESTATUS[0]}
    set -e
    exit "${rc}"
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid nohup "${worker[@]}" > "${OUT_DIR}/health.log" 2>&1 < /dev/null &
  else
    nohup "${worker[@]}" > "${OUT_DIR}/health.log" 2>&1 < /dev/null &
  fi
  echo $! > "${OUT_DIR}/pid"
  echo "Health check started in the background (PID $!)."
  echo "  Follow the log: tail -f ${OUT_DIR}/health.log"
  echo "  Result:         cat ${OUT_DIR}/status ${OUT_DIR}/summary.txt"
  exit 0
fi

# ============================================================================
# Worker: run the steps inside the copy.
# ============================================================================

[[ -n "${OUT_DIR}" ]] || die "--worker needs --out"
REPO="${REPO_ROOT}"          # the worker runs from the copy
LOG_DIR="${OUT_DIR}/logs"
REPORT_DIR="${OUT_DIR}/reports"
TCL_DIR="${OUT_DIR}/tcl"
VIVADO_RUN_DIR="${OUT_DIR}/vivado-run"   # Vivado writes its journal files here
mkdir -p "${LOG_DIR}" "${REPORT_DIR}" "${TCL_DIR}" "${VIVADO_RUN_DIR}"

GCC_BIN=${RISCV_GCC:-riscv64-unknown-elf-gcc}
OBJCOPY_BIN=${RISCV_OBJCOPY:-riscv64-unknown-elf-objcopy}
GHDL_BIN=${GHDL:-ghdl}
SPIKE_BIN=${SPIKE:-spike}
YOSYS_BIN=${YOSYS:-yosys}
NETLISTSVG_BIN=${NETLISTSVG:-netlistsvg}

# Run Vivado in batch mode. The settings script is sourced in a subshell so
# that it does not change PATH for the other steps.
vivado_batch() {
  local log=$1; shift
  (
    if [[ -n "${VIVADO_SETTINGS}" ]]; then
      set +u
      # shellcheck disable=SC1090
      source "${VIVADO_SETTINGS}"
      set -u
    fi
    cd "${VIVADO_RUN_DIR}"
    vivado -mode batch -nojournal -log "${log}" "$@"
  )
}

vivado_available() {
  if [[ -n "${VIVADO_SETTINGS}" ]]; then
    [[ -f "${VIVADO_SETTINGS}" ]]
  else
    command -v vivado >/dev/null 2>&1
  fi
}

# Print the tools a step needs that are missing (empty output: all present).
missing_tools() {
  local step=$1 t
  local -a need=()
  local riscv=("${GCC_BIN}" "${OBJCOPY_BIN}" python3)
  case "${step}" in
    build)                need=("${riscv[@]}") ;;
    unit)                 need=("${GHDL_BIN}") ;;
    waves|isa|trace|stall) need=("${GHDL_BIN}" "${riscv[@]}") ;;
    golden)               need=("${SPIKE_BIN}" "${riscv[@]}") ;;
    schematic)            need=("${YOSYS_BIN}" "${GHDL_BIN}" "${NETLISTSVG_BIN}" node) ;;
    digitaljs)            need=("${YOSYS_BIN}" "${GHDL_BIN}" "${NETLISTSVG_BIN}" node npm
                                "${riscv[@]}") ;;
    vivado-sim|vivado-impl) need=("${riscv[@]}") ;;
    latex)                need=(latexmk make) ;;
    clean)                need=() ;;
  esac
  local -a missing=()
  for t in "${need[@]}"; do
    command -v -- "${t}" >/dev/null 2>&1 || missing+=("${t}")
  done
  if [[ "${step}" == digitaljs && ${#missing[@]} -eq 0 ]]; then
    NODE_PATH="$(npm root -g 2>/dev/null)" node -e "require('yosys2digitaljs/core')" \
      >/dev/null 2>&1 || missing+=("yosys2digitaljs (npm module)")
  fi
  if [[ "${step}" == vivado-* ]] && ! vivado_available; then
    missing+=("vivado (use --xilinx-dir)")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "${missing[*]}"
  fi
}

# Print the source file (.c or .S) of an ISA test.
test_source() {
  local name=$1 ext
  for ext in c S; do
    if [[ -f "${REPO}/tests/isa/${name}.${ext}" ]]; then
      echo "${REPO}/tests/isa/${name}.${ext}"
      return 0
    fi
  done
  echo "error: no tests/isa/${name}.c or .S" >&2
  return 1
}

# Create the Vivado project for one board (the documented command).
vivado_create_project() {
  local board=$1
  local src log="${LOG_DIR}/vivado_create_${board}.log"
  local -a clk_args=()
  [[ -n "${CLK_MHZ}" ]] && clk_args=(--clk-mhz "${CLK_MHZ}")
  # Explicit `|| return 1`: this function is also called from an `if`, where
  # `set -e` has no effect.
  src=$(test_source "${VIVADO_TEST}") || return 1
  ./scripts/build_prog.sh "${src}" "${VIVADO_TEST}" || return 1
  rm -rf "${REPO}/build/vivado/${VIVADO_TEST}" "${log}"
  vivado_batch "${log}" \
    -source "${REPO}/scripts/vivado_project.tcl" \
    -tclargs "${VIVADO_TEST}" "${board}" "${clk_args[@]}" || return 1
  grep -E '^INFO: (board|core clock)' "${log}" || true
  if grep -E '^WARN: XDC' "${log}"; then
    echo "the XDC clock period does not match the board clock"
    return 1
  fi
  [[ -f "${REPO}/build/vivado/${VIVADO_TEST}/minrv32_${VIVADO_TEST}.xpr" ]]
}

# ------------------------------- Step bodies ---------------------------------
# Each step runs in a subshell with `set -e`, from the copy's root directory.
# A non-zero exit status marks the step as FAIL.

step_build() {
  local src name count=0
  shopt -s nullglob
  for src in tests/isa/*.c tests/isa/*.S; do
    name=$(basename "${src%.*}")
    echo "===> Building ${name}"
    ./scripts/build_prog.sh "${src}" "${name}"
    [[ -s "build/${name}.text.hex" ]] || { echo "missing build/${name}.text.hex"; return 1; }
    count=$((count + 1))
  done
  [[ ${count} -gt 0 ]] || { echo "no test sources found"; return 1; }
  echo "Built ${count} programs."
}

step_unit() {
  ./scripts/run_unit_tests.sh
}

step_waves() {
  ./scripts/run_unit_tb.sh --fst alu
  [[ -s build/waves/tb_alu.fst ]] || { echo "missing build/waves/tb_alu.fst"; return 1; }
  ./scripts/run_test.sh --fst addi_only
  [[ -s build/waves/addi_only.fst ]] || { echo "missing build/waves/addi_only.fst"; return 1; }
  ls -l build/waves/
}

step_isa() {
  ./scripts/run_tests.sh
}

step_trace() {
  local out="${LOG_DIR}/trace_addi_only.txt"
  ./scripts/run_test.sh --trace addi_only > "${out}" 2>&1 || { cat "${out}"; return 1; }
  cat "${out}"
  grep -q 'FETCH: PC=' "${out}" || { echo "no 'FETCH: PC=' lines in the trace"; return 1; }
}

step_stall() {
  FORWARDING_ENABLE=false ./scripts/run_tests.sh
}

step_golden() {
  ./scripts/check_goldens.sh
}

step_schematic() {
  ./scripts/gen_schematic.sh --all
  local count
  count=$(find build/schematics -name '*.svg' | wc -l)
  echo "SVG files written: ${count}"
  [[ ${count} -gt 0 ]]
}

step_digitaljs() {
  ./scripts/gen_schematic.sh --digitaljs alu
  [[ -s build/schematics/alu.digitaljs.json ]] \
    || { echo "missing build/schematics/alu.digitaljs.json"; return 1; }

  local out="${LOG_DIR}/digitaljs_top.txt"
  ./scripts/build_prog.sh tests/isa/full_core.c full_core
  ./scripts/gen_schematic.sh --digitaljs \
    --mem-init imem_dp=build/full_core.text.hex \
    --mem-init dmem=build/full_core.data.hex \
    top > "${out}" 2>&1 || { cat "${out}"; return 1; }
  cat "${out}"
  [[ -s build/schematics/top.digitaljs.json ]] \
    || { echo "missing build/schematics/top.digitaljs.json"; return 1; }
  grep -q '\[INIT\] imem_dp' "${out}" || { echo "imem_dp was not loaded by --mem-init"; return 1; }
  grep -q '\[INIT\] dmem' "${out}" || { echo "dmem was not loaded by --mem-init"; return 1; }
}

step_vivado_sim() {
  local board=${BOARDS[0]}
  local proj="${REPO}/build/vivado/${VIVADO_TEST}"
  vivado_create_project "${board}"

  cat > "${TCL_DIR}/xsim.tcl" <<'EOF'
# Open the project and run the behavioural simulation. The run time ("all")
# comes from vivado_project.tcl, so this also checks that setting.
open_project [lindex $argv 0]
launch_simulation
close_sim
EOF
  vivado_batch "${LOG_DIR}/vivado_xsim.log" \
    -source "${TCL_DIR}/xsim.tcl" -tclargs "${proj}/minrv32_${VIVADO_TEST}.xpr"

  local simlog
  simlog=$(find "${proj}" -name simulate.log | head -n 1)
  [[ -n "${simlog}" ]] || { echo "no simulate.log found under ${proj}"; return 1; }
  cp "${simlog}" "${LOG_DIR}/xsim_simulate.log"
  cat "${simlog}"
  grep -q 'TEST PASSED' "${simlog}" || { echo "XSim did not print TEST PASSED"; return 1; }
}

step_vivado_impl() {
  local proj="${REPO}/build/vivado/${VIVADO_TEST}"
  cat > "${TCL_DIR}/impl.tcl" <<'EOF'
# Synthesis, checks on the synthesized design, implementation and bitstream.
# Arguments: <xpr> <jobs> <report dir>
set xpr     [lindex $argv 0]
set jobs    [lindex $argv 1]
set rptdir  [lindex $argv 2]
file mkdir $rptdir

proc fail {msg} { puts "HEALTH: FAIL: $msg"; exit 1 }

open_project $xpr

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { fail "synthesis did not finish" }

open_run synth_1
set ndebug [llength [get_nets -hier -filter {MARK_DEBUG}]]
set nbram  [llength [get_cells -hier -filter {REF_NAME =~ RAMB*}]]
puts "HEALTH: nets with MARK_DEBUG after synthesis: $ndebug"
puts "HEALTH: block RAM cells after synthesis: $nbram"
report_utilization -file [file join $rptdir utilization_synth.rpt]
close_design
if {$ndebug == 0} { fail "no MARK_DEBUG nets in the synthesized design" }
if {$nbram == 0}  { fail "no block RAM cells in the synthesized design" }

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { fail "implementation did not finish" }

open_run impl_1
set path [get_timing_paths -setup -max_paths 1]
set wns  [get_property SLACK $path]
set period [get_property PERIOD [get_property ENDPOINT_CLOCK $path]]
puts "HEALTH: worst setup slack (WNS): $wns ns"
if {$wns ne "" && $period ne ""} {
  puts [format "HEALTH: clock of the worst path: %s, period %.3f ns (%.2f MHz)" \
          [get_property ENDPOINT_CLOCK $path] $period [expr {1000.0 / $period}]]
  # Rough estimate: assumes the worst path keeps the same delay at another
  # clock period. Implementation at a new frequency gives a different result.
  puts [format "HEALTH: estimated highest clock that meets timing: %.2f MHz" \
          [expr {1000.0 / ($period - $wns)}]]
}
report_timing_summary -file [file join $rptdir timing_summary.rpt]
report_utilization    -file [file join $rptdir utilization_impl.rpt]

set bit [glob -nocomplain [file join [get_property DIRECTORY [get_runs impl_1]] *.bit]]
if {$bit eq ""} { fail "no bitstream was written" }
file copy -force [lindex $bit 0] $rptdir
puts "HEALTH: bitstream: [lindex $bit 0]"
if {$wns eq "" || $wns < 0} { fail "setup timing not met (WNS = $wns)" }
puts "HEALTH: PASS"
exit 0
EOF

  local board rc=0
  for board in "${BOARDS[@]}"; do
    echo "===> Board ${board}"
    if ! vivado_create_project "${board}"; then
      echo "FAIL: ${board}: project creation"
      rc=1
      continue
    fi
    if vivado_batch "${LOG_DIR}/vivado_impl_${board}.log" \
         -source "${TCL_DIR}/impl.tcl" \
         -tclargs "${proj}/minrv32_${VIVADO_TEST}.xpr" "${JOBS}" "${REPORT_DIR}/${board}"; then
      echo "PASS: ${board}"
    else
      echo "FAIL: ${board}"
      rc=1
    fi
    grep '^HEALTH:' "${LOG_DIR}/vivado_impl_${board}.log" || true
  done
  return "${rc}"
}

step_latex() {
  local pdf=latex/manual/main.pdf before=0 after
  [[ -f "${pdf}" ]] && before=$(stat -c %Y "${pdf}")
  make -C latex pdf
  after=$(stat -c %Y "${pdf}" 2>/dev/null || echo 0)
  [[ "${after}" -gt "${before}" ]] || { echo "${pdf} was not rebuilt"; return 1; }
  ls -l "${pdf}"
}

step_clean() {
  ./scripts/clean.sh
  [[ ! -e build ]] || { echo "build/ still exists after clean.sh"; return 1; }
}

# ------------------------------- Step runner ---------------------------------

in_list() {
  local item=$1 list=$2
  [[ ",${list}," == *",${item},"* ]]
}

RESULTS=()   # lines for the summary
n_pass=0
n_fail=0
n_skip=0

record() {
  local step=$1 result=$2 secs=$3 note=$4
  local line
  line=$(printf '%-12s %-5s %6ss  %s' "${step}" "${result}" "${secs}" "${note}")
  RESULTS+=("${line}")
  echo "[${result}] ${step} (${secs}s) ${note}"
  case "${result}" in
    PASS) n_pass=$((n_pass + 1)) ;;
    FAIL) n_fail=$((n_fail + 1)) ;;
    SKIP) n_skip=$((n_skip + 1)) ;;
  esac
}

run_step() {
  local idx=$1 step=$2
  local log
  log=$(printf '%s/%02d_%s.log' "${LOG_DIR}" "${idx}" "${step}")
  local start=${SECONDS} missing rc

  missing=$(missing_tools "${step}")
  if [[ -n "${missing}" ]]; then
    record "${step}" SKIP 0 "missing: ${missing}"
    return 0
  fi
  if [[ "${step}" == clean && ${n_fail} -gt 0 ]]; then
    record "${step}" SKIP 0 "an earlier step failed; build files kept for debugging"
    return 0
  fi

  echo ""
  echo "===== ${step} (log: ${log})"
  set +e
  ( set -e; cd "${REPO}"; "step_${step//-/_}" ) > "${log}" 2>&1
  rc=$?
  set -e

  if [[ ${rc} -eq 0 ]]; then
    record "${step}" PASS $((SECONDS - start)) ""
  else
    echo "--- last 30 lines of ${log}:"
    tail -n 30 "${log}" | sed 's/^/    /'
    record "${step}" FAIL $((SECONDS - start)) "see ${log}"
  fi
}

# Print the location and version of a tool, or "not found".
tool_line() {
  local name=$1; shift
  local path
  if path=$(command -v -- "${name}" 2>/dev/null); then
    printf '  %-28s %s  (%s)\n' "${name}" "${path}" \
      "$("${name}" "$@" 2>&1 | head -n 1 || true)"
  else
    printf '  %-28s not found\n' "${name}"
  fi
}

echo "MinRV32 health check"
echo "Started:    $(date '+%Y-%m-%d %H:%M:%S')"
echo "Source:     $(cat "${OUT_DIR}/source.txt" 2>/dev/null || echo unknown)"
echo "Copy:       ${REPO}"
echo "Output:     ${OUT_DIR}"
echo "Boards:     ${BOARDS[*]} (Vivado program: ${VIVADO_TEST})"
echo "Vivado:     ${VIVADO_SETTINGS:-$(command -v vivado || echo 'not found')}"
echo "Tools:"
tool_line "${GHDL_BIN}" --version
tool_line "${GCC_BIN}" --version
tool_line "${OBJCOPY_BIN}" --version
tool_line python3 --version
tool_line "${SPIKE_BIN}" --help
tool_line "${YOSYS_BIN}" -V
tool_line "${NETLISTSVG_BIN}" --version
tool_line node --version
tool_line latexmk -v

idx=0
for step in "${ALL_STEPS[@]}"; do
  idx=$((idx + 1))
  if [[ -n "${ONLY_LIST}" ]] && ! in_list "${step}" "${ONLY_LIST}"; then continue; fi
  if [[ -n "${SKIP_LIST}" ]] && in_list "${step}" "${SKIP_LIST}"; then continue; fi
  run_step "${idx}" "${step}"
done

status=PASS
[[ ${n_fail} -gt 0 ]] && status=FAIL
[[ "${STRICT}" == true && ${n_skip} -gt 0 ]] && status=FAIL

{
  echo "MinRV32 health check: ${status}"
  echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Source:   $(cat "${OUT_DIR}/source.txt" 2>/dev/null || echo unknown)"
  echo ""
  printf '%-12s %-5s %7s  %s\n' STEP RESULT TIME NOTE
  printf '%s\n' "${RESULTS[@]}"
  echo ""
  echo "${n_pass} passed, ${n_fail} failed, ${n_skip} skipped."
  echo "Not covered: view_wave.sh (GUI), board programming and ILA capture (need a board)."
} > "${OUT_DIR}/summary.txt"

echo ""
cat "${OUT_DIR}/summary.txt"
echo "${status}" > "${OUT_DIR}/status"

[[ "${status}" == PASS ]]
