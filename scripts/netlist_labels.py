#!/usr/bin/env python3
"""
netlist_labels.py

Post-process a Yosys JSON netlist to make schematics human-readable.

Two independent passes (can be run separately or together):

  --demangle   Strip GHDL generic-hash suffixes from module names.
               GHDL mangles entity names when generics are used, e.g.
               ``hazard_unit_bf8b4530``.  This pass renames them back to
               ``hazard_unit`` and updates all cell type references.
               Safe to run before yosys2digitaljs (no module duplication).

  --relabel    Replace generic module type labels with VHDL instance labels.
               For each cell whose type matches an existing module name and
               whose instance name differs, the module definition is
               duplicated under the instance name and the cell's type is
               rewritten.  This *duplicates* modules and must run AFTER
               yosys2digitaljs (which cannot handle duplicated modules).

With no flags, both passes run in order (demangle then relabel) -- this is
the legacy behaviour used by the SVG rendering path.

Usage:
    python3 scripts/netlist_labels.py [--demangle|--relabel] <netlist.json>

The file is modified in place.
"""

import json
import re
import sys

# GHDL appends a hex hash (>= 8 chars) after the entity name when generics
# are present, e.g. ``hazard_unit_bf8b4530``.  The regex captures the base
# entity name (which may itself contain underscores) and the trailing hash.
_GHDL_HASH_RE = re.compile(r"^(.+)_([0-9a-f]{8,})$")


def demangle_ghdl_names(data: dict) -> None:
    """Strip GHDL generic-hash suffixes from module names in place."""
    modules = data.get("modules", {})

    # Build rename map: mangled name -> base name.
    rename_map: dict[str, str] = {}
    for name in list(modules):
        m = _GHDL_HASH_RE.match(name)
        if m:
            rename_map[name] = m.group(1)

    if not rename_map:
        return

    # Rename module keys.
    for old, new in rename_map.items():
        modules[new] = modules.pop(old)

    # Update cell type references throughout all modules.
    for mod in modules.values():
        for cell in mod.get("cells", {}).values():
            ctype = cell.get("type", "")
            if ctype in rename_map:
                cell["type"] = rename_map[ctype]


def relabel(data: dict) -> None:
    """Replace module type labels with VHDL instance labels."""
    modules = data.get("modules", {})
    additions = {}
    for mod in modules.values():
        for inst_name, cell in mod.get("cells", {}).items():
            ctype = cell.get("type", "")
            if ctype in modules and inst_name != ctype:
                additions[inst_name] = modules[ctype]
                cell["type"] = inst_name
    modules.update(additions)


def process(path: str, do_demangle: bool, do_relabel: bool) -> None:
    with open(path) as f:
        data = json.load(f)
    if do_demangle:
        demangle_ghdl_names(data)
    if do_relabel:
        relabel(data)
    with open(path, "w") as f:
        json.dump(data, f)


if __name__ == "__main__":
    args = sys.argv[1:]
    do_demangle = "--demangle" in args
    do_relabel = "--relabel" in args
    args = [a for a in args if a not in ("--demangle", "--relabel")]

    if len(args) != 1:
        print(
            f"Usage: {sys.argv[0]} [--demangle|--relabel] <netlist.json>",
            file=sys.stderr,
        )
        sys.exit(1)

    # No flags = both passes (legacy behaviour).
    if not do_demangle and not do_relabel:
        do_demangle = True
        do_relabel = True

    process(args[0], do_demangle, do_relabel)
