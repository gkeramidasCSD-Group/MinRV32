# Prerequisites

This page lists the tools that the project uses and shows how to install them
on Ubuntu 24.04. There are two ways to install:

- **Mode A, with `sudo`:** `sudo` runs a command with administrator rights.
  With it you install system packages with `apt`, Ubuntu's package manager.
- **Mode B, without `sudo`:** you install everything in your home directory.

Both modes end with the same check, in [section 5](#5-check-the-installation).

A *terminal* in this page is a shell window, for example the Ubuntu
"Terminal" application. `PATH` is the list of directories that the shell
searches for programs. A command that is not in a `PATH` directory gives the
error `command not found`.

---

## 1. Which tools you need

You need only the tools for the steps you want to run. The steps follow the
[Learning path](learning_path.md).

| Tool | What it is | Used by | Needed for |
|------|------------|---------|------------|
| RISC-V GCC (`riscv64-unknown-elf-gcc`, `riscv64-unknown-elf-objcopy`) | C compiler and binary tools for RISC-V | `build_prog.sh`, and every script that builds a test program | **Required** |
| Python 3 | Script interpreter (only standard library modules are used) | `build_prog.sh`, `gen_schematic.sh` | **Required** |
| GHDL | VHDL simulator | `run_unit_tb.sh`, `run_unit_tests.sh`, `run_test.sh`, `run_tests.sh` | **Required** |
| GTKWave | Waveform viewer (opens a window) | `view_wave.sh` | Optional: viewing waveforms |
| Yosys, the Yosys GHDL plugin, Node.js, netlistsvg | Synthesis tool, its VHDL reader, JavaScript runtime, schematic drawer | `gen_schematic.sh` | Optional: schematics |
| Graphviz (`dot`) | Graph drawer | `gen_schematic.sh --dot` | Optional |
| yosys2digitaljs | Converts a Yosys netlist for the DigitalJS web simulator | `gen_schematic.sh --digitaljs` | Optional: DigitalJS |
| Spike and `dtc` | RISC-V reference simulator, and the device-tree compiler that Spike runs | `gen_golden.sh`, `check_goldens.sh` | Optional: creating or checking `.sig` files |
| TeX Live with `latexmk`, and `make` | LaTeX system, and the build tool that runs it | `make -C latex` | Optional: rebuilding the manual PDF |
| Vivado | AMD FPGA tools | `vivado_project.tcl`, [Vivado instructions](vivado_instructions.md) | Optional: FPGA flow |

If your RISC-V GCC has another name, or is not in `PATH`, set the
environment variables `RISCV_GCC` and `RISCV_OBJCOPY` to the full paths of the
compiler and of `objcopy`. `build_prog.sh` uses them instead of
`riscv64-unknown-elf-gcc` and `riscv64-unknown-elf-objcopy`.

---

## 2. Mode A: install with `sudo` (Ubuntu 24.04)

### 2.1 Required tools

```sh
sudo apt update
sudo apt install -y gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf \
  python3 ghdl
```

### 2.2 Waveform viewer

```sh
sudo apt install -y gtkwave
```

### 2.3 Schematics and DigitalJS

```sh
sudo apt install -y yosys yosys-plugin-ghdl graphviz nodejs npm
sudo npm install -g netlistsvg yosys2digitaljs
```

### 2.4 Spike

Spike has no Ubuntu package, so you build it from source. The build needs a
C++ compiler, `make`, `git`, and `dtc`:

```sh
sudo apt install -y build-essential git device-tree-compiler
git clone https://github.com/riscv-software-src/riscv-isa-sim.git
cd riscv-isa-sim && mkdir build && cd build
../configure --prefix=/opt/riscv
make -j"$(nproc)"
sudo make install
```

Then add `/opt/riscv/bin` to `PATH` (see [section 4](#4-add-the-tools-to-path)).
The Boost development packages are not needed: the Spike used to check this
page was built on a machine without them.

### 2.5 LaTeX

```sh
sudo apt install -y make latexmk texlive-latex-base texlive-latex-recommended \
  texlive-latex-extra texlive-fonts-recommended
```

### 2.6 Vivado

See [section 3.6](#36-vivado); Vivado is installed the same way in both modes.

---

## 3. Mode B: install without `sudo`

All tools go into `~/tools` (`~` is your home directory). Create it first:

```sh
mkdir -p ~/tools
```

### 3.1 RISC-V GCC: unpack the Ubuntu packages

`apt-get download` fetches a package file without installing it, and
`dpkg -x` unpacks it into a directory. Neither needs `sudo`.

```sh
mkdir -p ~/tools/ubuntu-pkgs/debs && cd ~/tools/ubuntu-pkgs/debs
apt-get download gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
for d in *.deb; do dpkg -x "$d" ~/tools/ubuntu-pkgs; done
~/tools/ubuntu-pkgs/usr/bin/riscv64-unknown-elf-gcc --version
```

The last command must print a version. If it prints an error about a missing
`.so` library, the machine lacks a library that the compiler uses (the
package lists them: `apt-cache depends gcc-riscv64-unknown-elf`). Download
that package with `apt-get download`, unpack it the same way, and add
`~/tools/ubuntu-pkgs/usr/lib/x86_64-linux-gnu` to the `LD_LIBRARY_PATH`
variable.

### 3.2 GHDL, Yosys with the GHDL plugin, and GTKWave: OSS CAD Suite

OSS CAD Suite is a single archive from YosysHQ that contains GHDL, Yosys, the
Yosys GHDL plugin, GTKWave, and other tools. Download the newest
`oss-cad-suite-linux-x64-<date>.tgz` file from
https://github.com/YosysHQ/oss-cad-suite-build/releases, then unpack it:

```sh
tar -C ~/tools -xzf oss-cad-suite-linux-x64-<date>.tgz
~/tools/oss-cad-suite/bin/ghdl --version
~/tools/oss-cad-suite/bin/yosys -V
```

OSS CAD Suite also contains programs that you may already have, for example
Verilator. [Section 4](#4-add-the-tools-to-path) adds it at the *end* of
`PATH`, so a program you already have is still found first.

### 3.3 netlistsvg and yosys2digitaljs

These need Node.js and `npm`. Check with `node --version`. If Node.js is not
installed and you cannot use `sudo`, ask the administrator to install the
`nodejs` and `npm` packages; installing Node.js without `sudo` was not checked
for this page.

Tell `npm` to install global packages under `~/.local`, then install:

```sh
npm config set prefix "$HOME/.local"
npm install -g netlistsvg yosys2digitaljs
```

The programs land in `~/.local/bin`.

### 3.4 Spike

Use the commands of [section 2.4](#24-spike) without the `apt` and `sudo`
lines, with `--prefix=$HOME/.local` for `configure` and plain `make install`.
The build needs a C++ compiler, `make`, `git`, and `dtc`; check with
`g++ --version`, `make --version`, `git --version`, and `dtc --version`.
If `dtc` is missing, download and unpack the `device-tree-compiler` package as
in [section 3.1](#31-risc-v-gcc-unpack-the-ubuntu-packages).

### 3.5 LaTeX: TeX Live in your home directory

TeX Live's own installer can install into any directory. The profile file
below selects the small package set (`scheme-small`) and skips the
documentation files. The manual needs one more package, `placeins`, which
`scheme-small` does not contain; the last command installs it with `tlmgr`,
the TeX Live package manager.

```sh
mkdir -p ~/tools/downloads/texlive && cd ~/tools/downloads/texlive
curl -sSL -o install-tl-unx.tar.gz \
  https://mirror.ctan.org/systems/texlive/tlnet/install-tl-unx.tar.gz
tar -xzf install-tl-unx.tar.gz
cat > tl.profile <<EOF
selected_scheme scheme-small
TEXDIR $HOME/tools/texlive
TEXMFLOCAL $HOME/tools/texlive/texmf-local
TEXMFSYSVAR $HOME/tools/texlive/texmf-var
TEXMFSYSCONFIG $HOME/tools/texlive/texmf-config
TEXMFHOME $HOME/texmf
tlpdbopt_install_docfiles 0
tlpdbopt_install_srcfiles 0
instopt_adjustpath 0
EOF
perl install-tl-2*/install-tl --no-interaction --profile tl.profile
~/tools/texlive/bin/x86_64-linux/tlmgr install placeins
```

The programs, including `latexmk`, land in
`~/tools/texlive/bin/x86_64-linux`.

### 3.6 Vivado

Vivado is not open source. Download the Linux installer from AMD and run it.
The installer can install into a directory that you own; on the machine used
to check this page, Vivado 2024.2 is installed in a directory owned by the
user. The directory that you choose is called the *Xilinx directory* below;
it contains `Vivado/<version>/settings64.sh`.

Programming a board over USB also needs the JTAG cable drivers; installing
them was not checked for this page.

---

## 4. Add the tools to `PATH`

Add the lines for your mode at the end of `~/.bashrc`, then open a new
terminal. `$PATH:` at the start keeps the directories that are already in
`PATH` in front.

Mode A (only Spike is outside the standard directories):

```sh
export PATH="$PATH:/opt/riscv/bin"
```

Mode B:

```sh
export PATH="$PATH:$HOME/tools/ubuntu-pkgs/usr/bin:$HOME/tools/oss-cad-suite/bin"
export PATH="$PATH:$HOME/.local/bin:$HOME/tools/texlive/bin/x86_64-linux"
```

Vivado (both modes): do not add it to `~/.bashrc`. Load it in the terminal
where you need it, because its settings script also changes `PATH` for the
other AMD tools that are installed. For example, when AMD Vitis is installed,
the script puts Vitis' own `riscv64-unknown-elf-gcc` (GCC 13.3) first in
`PATH`, in front of the RISC-V GCC you installed. The project's build works
with that compiler too (all ISA tests and Spike signature checks pass with
it), but the compiler is a different one:

```sh
source <xilinx-dir>/Vivado/<version>/settings64.sh
```

`scripts/health_check.sh` does this for you with `--xilinx-dir <xilinx-dir>`.

---

## 5. Check the installation

Each command must print a version or a path, not `command not found` or
nothing:

```sh
riscv64-unknown-elf-gcc --version
python3 --version
ghdl --version
command -v gtkwave
yosys -V
command -v netlistsvg
spike --help | grep debug-cmd
make --version
latexmk -v
```

(`gtkwave --version` needs a graphical display, so the check uses
`command -v`, which prints where the program is.)

Then run every automated test (about 20 minutes, most of it Vivado):

```sh
./scripts/health_check.sh --foreground --strict --xilinx-dir <xilinx-dir>
```

The last lines must show `MinRV32 health check: PASS` and
`13 passed, 0 failed, 0 skipped.` A step whose tools are missing is reported
as `SKIP` with the missing tool names. [Scripts overview](scripts.md#health_checksh)
describes the script, and [Manual testing](manual_testing.md) shows how to run
the same tests by hand and check the results that open in a window.

---

## 6. What was checked for this page

The commands were checked on Ubuntu 24.04 in October 2026.

| Item | How it was checked |
|------|--------------------|
| Every package name in Mode A | `apt-cache policy` shows a version for each one. |
| Mode A GCC 13.2.0, GHDL 4.1.0, Yosys 0.33 with its GHDL plugin | The Ubuntu packages were downloaded and unpacked (no `sudo` was available), and `health_check.sh` passed the steps `build`, `unit`, `waves`, `isa`, `trace`, `stall`, `golden`, `schematic`, and `digitaljs` with them. |
| Mode A packages, `sudo npm install`, GTKWave and LaTeX packages | On a second machine where all of them had been installed with `sudo`, `apt-get install -s` (a dry run, no `sudo` needed) reported every package of section 2 as installed at the newest version, and all 13 steps of `health_check.sh --strict` passed with them (TeX Live 2023, latexmk 4.83). The `sudo` commands themselves were not re-run. |
| Mode B GCC (section 3.1) | Same unpacked packages as above. |
| Mode B OSS CAD Suite (release 2026-10-10: GHDL 7.0.0-dev, Yosys 0.69), npm, TeX Live 2026 | Installed with the commands above, then put in front of `PATH` so that they were used instead of the Mode A tools of the same machine. Every step of `health_check.sh` except the two Vivado steps passed (Vivado is the same in both modes). Without `tlmgr install placeins`, the `latex` step fails with ``File `placeins.sty' not found``. |
| Spike build (sections 2.4 and 3.4) | Built with the commands of section 3.4 (`--prefix` in the home directory); `spike --help` lists `--debug-cmd`, and the `golden` step passed with it. The machine had the Boost development packages, so this build linked with them. |
| Vivado 2024.2 | Used for the `vivado-sim` and `vivado-impl` steps. |

---

[<- Back to documentation overview](../README.md#documentation-at-a-glance)
