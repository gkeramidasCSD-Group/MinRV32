# LaTeX project: MinRV32 documentation

This folder contains a small LaTeX project that turns the repository's `docs/`
content into a single, easy-to-read PDF suitable for sharing/teaching.

## Build (recommended: latexmk)

You need a LaTeX distribution plus `latexmk` (e.g., TeX Live).

```sh
cd latex/manual
latexmk -pdf -interaction=nonstopmode -halt-on-error main.tex
```

Output: `latex/manual/main.pdf`

## Build (alternative: Makefile)

The `Makefile` in this folder wraps `latexmk` and exposes four targets:

| Target      | Command            | What it does                                                                  |
|-------------|--------------------|-------------------------------------------------------------------------------|
| `make`      | `latexmk -pdf ...` | Build `main.pdf` (default target).                                            |
| `make pdf`  | `latexmk -pdf ...`, then `latexmk -c -bibtex` | Build `main.pdf`, then remove every auxiliary file, so only `main.pdf` remains. |
| `make tidy` | `latexmk -c`       | Remove auxiliary/intermediate files (`.aux`, `.log`, `.toc`, `.out`, etc.) but keep `main.pdf`. |
| `make clean`| `latexmk -C`       | Remove all generated files, **including** `main.pdf`.                          |

```sh
cd latex/manual
make          # build main.pdf
make pdf      # build main.pdf, keep only main.pdf
make tidy     # delete intermediates, keep main.pdf
make clean    # delete everything, including main.pdf
```

Each target checks that `latexmk` is installed and prints a hint if it is
missing.

## Installing TeX Live

See [Prerequisites](../../docs/prerequisites.md): section 2.5 installs TeX
Live with `sudo`, and section 3.5 installs it in your home directory.
