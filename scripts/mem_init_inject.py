#!/usr/bin/env python3
"""
mem_init_inject.py - Inject memory initial values into a Yosys JSON netlist.

Background
----------
Yosys/GHDL synthesis excludes the ``synthesis translate_off/on`` blocks
in ``mem_init_pkg.vhd``, so the ``init_mem()`` file-I/O call is never
executed.  Every ``$mem`` / ``$mem_v2`` cell in the resulting netlist
therefore has its INIT parameter set to all-'x' (uninitialised), which
DigitalJS and other netlist consumers interpret as all-zero at simulation
start.

This script patches the INIT parameter of matching cells by reading the
same plain-text hex files that GHDL simulation uses, giving the DigitalJS
interactive simulation a faithful firmware image.

Usage
-----
    python3 scripts/mem_init_inject.py \\
        --json  build/schematics/<entity>.json \\
        --module imem_dp --hex build/<prog>.text.hex \\
        --module dmem    --hex build/<prog>.data.hex

Each ``--module`` / ``--hex`` pair is processed in the order given.
The JSON file is modified in place.

Module matching
---------------
The ``--module`` name is matched against the Yosys JSON module table
using prefix matching so that GHDL-mangled names (e.g.
``imem_dp_bf8b4530``) are found even if ``--demangle`` has not been run
yet.  Once ``netlist_labels.py --demangle`` has been applied, exact names
(e.g. ``imem_dp``) match directly.

INIT encoding
-------------
Yosys encodes the INIT parameter as a flat binary string (characters
'0', '1', or 'x') of total length WIDTH * DEPTH.  Word address 0
occupies the least-significant WIDTH bits (rightmost in the string) and
word address DEPTH-1 occupies the most-significant WIDTH bits
(leftmost).  Within each word, bit [WIDTH-1] (MSB) is the leftmost
character.  In other words:

    INIT = bin(word[DEPTH-1]) ++ bin(word[DEPTH-2]) ++ ... ++ bin(word[0])

where each binary representation is zero-padded to WIDTH characters.

Hex file format
---------------
One unsigned 32-bit word per line, as produced by ``bin_to_hex.py``
(e.g. ``deadbeef``).  Blank lines are ignored.  Words beyond DEPTH are
silently discarded; addresses without a corresponding hex line are left
as 0.
"""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def load_hex(path: str) -> list[int]:
    """Return a list of 32-bit ints read from a one-word-per-line hex file."""
    words: list[int] = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line:
                continue
            try:
                words.append(int(line, 16))
            except ValueError:
                sys.exit(
                    f"error: {path}:{lineno}: cannot parse hex word: {line!r}"
                )
    return words


def build_init_string(words: list[int], depth: int, width: int = 32) -> str:
    """Encode *words* as a Yosys INIT binary parameter string.

    The Yosys INIT convention places word[0] at the least-significant end
    (rightmost characters) and word[DEPTH-1] at the most-significant end
    (leftmost characters).  Each individual word is encoded MSB-first.
    """
    padded = list(words) + [0] * max(0, depth - len(words))
    padded = padded[:depth]  # truncate if the hex file exceeds DEPTH
    # Reverse so that word[depth-1] is emitted first (leftmost = MSB end).
    return "".join(format(w, f"0{width}b") for w in reversed(padded))


# ---------------------------------------------------------------------------
# Core logic
# ---------------------------------------------------------------------------

_MEM_CELL_TYPES = frozenset(("$mem", "$mem_v2"))


def _param_to_int(value: int | str) -> int:
    """Convert a Yosys JSON parameter value to a Python int.

    Yosys encodes integer parameters as binary strings (e.g. ``"0100"``
    for 4) in most cases, but some versions or cell types emit plain JSON
    integers.  Handle both transparently.
    """
    if isinstance(value, int):
        return value
    # Binary string -- may contain only '0'/'1' characters.
    return int(value, 2)


def patch_module(mod_name: str, mod_data: dict[str, Any], hex_path: str) -> int:
    """Patch every ``$mem`` / ``$mem_v2`` cell in *mod_data* with *hex_path*.

    Returns the number of cells patched.
    """
    words = load_hex(hex_path)
    cells: dict[str, Any] = mod_data.get("cells", {})
    patched = 0

    for cell_name, cell in cells.items():
        if cell.get("type") not in _MEM_CELL_TYPES:
            continue

        params: dict[str, Any] = cell.get("parameters", {})

        # Yosys encodes integer parameters as binary strings in most
        # cases, but some versions emit plain JSON integers -- _param_to_int
        # handles both.
        width_raw = params.get("WIDTH")
        # Older Yosys uses SIZE; newer versions use DEPTH.
        depth_raw = params.get("DEPTH") or params.get("SIZE")

        if width_raw is None or depth_raw is None:
            print(
                f"  [WARN] {mod_name}/{cell_name}: missing WIDTH or DEPTH/SIZE"
                " parameter - skipping",
                file=sys.stderr,
            )
            continue

        width = _param_to_int(width_raw)
        depth = _param_to_int(depth_raw)

        if width == 0 or depth == 0:
            continue

        params["INIT"] = build_init_string(words, depth, width)
        patched += 1
        print(
            f"  [INIT] {mod_name}/{cell_name}: "
            f"{len(words)} word(s) loaded, depth={depth}, width={width}"
        )

    return patched


def inject(netlist: dict, module_patterns: list[str], hex_files: list[str]) -> int:
    """Patch modules whose names match *module_patterns* with corresponding hex files.

    Matching uses exact name or prefix (to handle GHDL-mangled names such as
    ``imem_dp_bf8b4530`` when the pattern is ``imem_dp``).

    Returns the total number of cells patched across all modules.
    """
    modules: dict = netlist.get("modules", {})
    total = 0

    for pattern, hex_path in zip(module_patterns, hex_files):
        sep = pattern + "_"
        for mod_name, mod_data in modules.items():
            if mod_name == pattern or mod_name.startswith(sep):
                total += patch_module(mod_name, mod_data, hex_path)

    return total


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description=(
            "Inject hex-file initial values into Yosys JSON $mem/$mem_v2 cells."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Each --module/--hex pair must be given together and in order.\n"
            "Example:\n"
            "  %(prog)s --json build/schematics/riscvpipe.json \\\n"
            "      --module imem_dp --hex build/full_core.text.hex \\\n"
            "      --module dmem    --hex build/full_core.data.hex"
        ),
    )
    ap.add_argument(
        "--json",
        required=True,
        metavar="NETLIST",
        help="Yosys JSON netlist to patch (modified in place)",
    )
    ap.add_argument(
        "--module",
        action="append",
        dest="modules",
        default=[],
        metavar="MODULE",
        help=(
            "Module name whose $mem/$mem_v2 cell(s) should be initialised "
            "(repeatable; paired with the following --hex)"
        ),
    )
    ap.add_argument(
        "--hex",
        action="append",
        dest="hexfiles",
        default=[],
        metavar="HEX_FILE",
        help="Hex file for the preceding --module (repeatable)",
    )
    args = ap.parse_args()

    if len(args.modules) != len(args.hexfiles):
        sys.exit(
            "error: --module and --hex must appear in matched pairs "
            "(one --hex immediately after each --module)"
        )

    with open(args.json) as fh:
        netlist = json.load(fh)

    total = inject(netlist, args.modules, args.hexfiles)

    with open(args.json, "w") as fh:
        json.dump(netlist, fh)

    if total == 0:
        print(
            "  [WARN] No $mem/$mem_v2 cells were patched. "
            "Check that --module names match entries in the JSON netlist.",
            file=sys.stderr,
        )
    sys.exit(0)


if __name__ == "__main__":
    main()
