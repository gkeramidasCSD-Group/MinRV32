# LaTeX projects: MinRV32

This directory holds the LaTeX deliverables for the MinRV32 project. The
genuinely shared *assets* (figures and sample output) live in a single place
(`common/`); the manual keeps its own style and bibliography, so it stays
decoupled from those shared assets.

```
latex/
  common/            shared assets only (no shared styling decisions)
    figures/         figures (PDF + SVG) + editable source (.drawio)
    sample_output/   trace/output snippets
  manual/            coursework-friendly documentation (article class)
                     owns its listings style, Tcl language def, bibliography
  Makefile           build the manual
```

## How sharing works

`manual/` pulls the shared assets from `common/` via relative paths
(`\graphicspath`, `\lstinputlisting`). Style (`\lstdefinestyle`, `\ProjectName`)
and bibliography are defined locally in the manual.

## Build

```sh
cd latex
make            # build manual/main.pdf
make manual     # same as `make` (build the manual)
make pdf        # build the manual, then delete all aux files (only the PDF remains)
make tidy       # remove intermediate aux files but keep the built PDF
make clean      # remove all generated files, including build/
```

`make pdf` is the "give me clean output" target: it builds and then removes
every auxiliary file (`.aux`, `.log`, `.bbl`, …), leaving only `main.pdf`.
`make tidy` is lighter — it sweeps the intermediates but keeps the PDF (and
`.bbl`) in place.

The manual also has its own `Makefile` if you prefer to build it directly
(e.g. `cd manual && make`).

## Diagrams

The microarchitecture block schematics (`common/figures/uarch_*.{svg,pdf}`) are
generated from the RTL with Yosys + `netlistsvg` via
[`scripts/gen_schematic.sh`](../scripts/gen_schematic.sh) (hierarchical mode).
They are the same diagrams embedded in
[`docs/microarchitecture.md`](../docs/microarchitecture.md) (which uses the
`.svg`), at four levels:

| File | Entity | Level |
|------|--------|-------|
| `uarch_system`  | `top`           | core + instruction/data memories |
| `uarch_core`    | `riscvpipe`     | controller / datapath / hazard unit |
| `uarch_stages`  | `datapath_pipe` | the five pipeline stage wrappers |
| `uarch_execute` | `execute_stage` | ALU, branch unit, muxes, D->E registers |

Both the `.svg` and the committed `.pdf` (used by the manual) are
checked in, so a normal `make` needs no schematic toolchain. To regenerate after
RTL changes you need Yosys + `yosys-plugin-ghdl` + `netlistsvg` (for the SVGs)
and `rsvg-convert` for the SVG->PDF step (`sudo apt install librsvg2-bin`):

```sh
# run from the latex/ directory
for e in top:uarch_system riscvpipe:uarch_core \
         datapath_pipe:uarch_stages execute_stage:uarch_execute; do
  src="${e%%:*}"; name="${e##*:}"; fig=common/figures
  # 1) re-render the SVG from RTL
  ../scripts/gen_schematic.sh -o "$fig" "$src"
  mv "$fig/$src.svg" "$fig/$name.svg"
  rm -f "$fig/$src.json"
  # 2) convert to a single-page, correctly-sized vector PDF
  rsvg-convert -f pdf -o "$fig/$name.pdf" "$fig/$name.svg"
done
```

`rsvg-convert` reads the SVG's intrinsic size, so the PDF is a single page sized
to the diagram automatically (no page-size handling needed). `inkscape
--export-type=pdf "$name.svg"` works as a drop-in alternative if you already have
Inkscape installed.

By default `gen_schematic.sh` removes don't-care (`x`) multiplexer inputs
(`opt_expr -mux_undef`) before rendering, so a result mux's default branch for
unused opcode encodings does not show up as a cluster of floating stubs wired to
nothing. This only resolves don't-cares, so the defined behaviour is unchanged;
pass `--keep-undef` to keep the raw elaborated form.

## Requirements

A TeX Live distribution with `latexmk`. The manual writes its bibliography
inline, so BibTeX is not needed. See [Prerequisites](../docs/prerequisites.md)
(section 2.5 with `sudo`, section 3.5 without).

Building the documents only needs TeX Live — the figures are committed. The
following are required *only* to regenerate the microarchitecture diagrams (see
[Diagrams](#diagrams) above):

- Yosys + `yosys-plugin-ghdl` + `netlistsvg` — render the SVGs from the RTL.
- `librsvg2-bin` (provides `rsvg-convert`) — convert the SVGs to PDF:

```sh
sudo apt install librsvg2-bin
```
