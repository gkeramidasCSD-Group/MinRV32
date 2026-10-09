#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# vhdl_entities.sh
#
# Shared entity discovery and hierarchy graph for the MinRV32 RTL.
#
# Provides:
#   ENTITY_FILE_MAP   - associative array: entity_name -> vhd_file_path
#   ALL_ENTITIES      - sorted indexed array of all entity names
#   ENTITY_CHILDREN   - associative array: entity_name -> space-separated children
#   compute_keep_entities <top> <max_depth>  - BFS: entities beyond depth
#   compute_all_descendants <top>            - BFS: all reachable descendants
#
# Requires REPO_ROOT to be set before sourcing.
#
# This file is intended to be *sourced* by other bash scripts:
#   source "${REPO_ROOT}/scripts/vhdl_entities.sh"
# -----------------------------------------------------------------------------

if [[ -z "${__MINRV32_VHDL_ENTITIES_SH_LOADED:-}" ]]; then
  __MINRV32_VHDL_ENTITIES_SH_LOADED=1

  [[ -n "${REPO_ROOT:-}" ]] \
    || { echo "error: REPO_ROOT must be set before sourcing vhdl_entities.sh" >&2; exit 1; }

  # ---- Build entity map: entity name -> VHDL source file -------------------
  declare -gA ENTITY_FILE_MAP

  for _vhd_file in "${REPO_ROOT}"/rtl/*.vhd; do
    while IFS= read -r _ent_name; do
      ENTITY_FILE_MAP["${_ent_name}"]="${_vhd_file}"
    done < <(grep -i -oP '^\s*entity\s+\K\w+(?=\s+is)' "${_vhd_file}" 2>/dev/null || true)
  done

  # Sorted list of all known entity names.
  mapfile -t ALL_ENTITIES < <(printf '%s\n' "${!ENTITY_FILE_MAP[@]}" | sort)

  # ---- Build hierarchy graph: entity name -> space-separated children ------
  declare -gA ENTITY_CHILDREN

  for _ent in "${!ENTITY_FILE_MAP[@]}"; do
    _file="${ENTITY_FILE_MAP[$_ent]}"
    _kids=$(grep -ioP 'entity\s+work\.\K\w+' "${_file}" 2>/dev/null \
      | sort -u | tr '\n' ' ' || true)
    ENTITY_CHILDREN["${_ent}"]="${_kids}"
  done

  unset _vhd_file _ent_name _ent _file _kids

  # ---- BFS helpers ---------------------------------------------------------

  # BFS from a root entity.  Returns entity names that should keep hierarchy
  # (i.e. depth > max_depth).  Only returns entities that are actually reachable
  # from the root, so Yosys won't warn about unrelated modules.
  compute_keep_entities() {
    local top="$1" max_depth="$2"
    local -A visited
    local -a queue=("${top}:0")
    visited["${top}"]=0

    while [[ ${#queue[@]} -gt 0 ]]; do
      local item="${queue[0]}"
      queue=("${queue[@]:1}")
      local current="${item%%:*}"
      local d="${item##*:}"

      for child in ${ENTITY_CHILDREN[$current]:-}; do
        if [[ -z "${visited[$child]:-}" ]]; then
          visited["$child"]=$((d + 1))
          queue+=("${child}:$((d + 1))")
        fi
      done
    done

    for ent in "${!visited[@]}"; do
      if [[ ${visited[$ent]} -gt $max_depth ]]; then
        echo "${ent}"
      fi
    done
  }

  # BFS from a root entity to collect ALL descendant entity names (excluding
  # the root itself).  Used by --expand to mark every child with keep_hierarchy
  # before selectively un-marking the ones the user wants to expand.
  compute_all_descendants() {
    local top="$1"
    local -A visited
    local -a queue=("${top}")
    visited["${top}"]=1

    while [[ ${#queue[@]} -gt 0 ]]; do
      local current="${queue[0]}"
      queue=("${queue[@]:1}")
      for child in ${ENTITY_CHILDREN[$current]:-}; do
        if [[ -z "${visited[$child]:-}" ]]; then
          visited["$child"]=1
          queue+=("${child}")
        fi
      done
    done

    for ent in "${!visited[@]}"; do
      [[ "${ent}" != "${top}" ]] && echo "${ent}"
    done
  }
fi
