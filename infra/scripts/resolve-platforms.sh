#!/bin/bash
# infra/scripts/resolve-platforms.sh — F50 / s013 helper.
#
# Resolves the effective platform set for a single commission, given
# (1) an optional section-brief path with a "Required platforms"
# field, (2) the project's TOP-LEVEL-PLAN.md with an optional
# "## Platforms" section, and (3) the s009 substrate state at
# .substrate-state/platforms.txt as a final fallback.
#
# Semantics (see s013 brief, design call 1):
#
#   - The TOP-LEVEL-PLAN.md "## Platforms" section is the project
#     superset. If absent, the project superset is derived from
#     .substrate-state/platforms.txt (s009's record of the setup-time
#     selection). If that's also absent / empty, the project superset
#     is empty.
#
#   - The section brief's "Required platforms" field is an optional
#     subset override. If present, it MUST be a subset of the project
#     superset; declaring a platform outside the superset fails
#     commission with a clear error.
#
#   - If the section is silent (no "Required platforms" field), the
#     section inherits the full project superset. Safe default;
#     potentially heavier than needed. Architects specify subsets
#     explicitly when sections specialise (per the new architect-
#     guide subsection added by s013).
#
# Usage:
#   resolve-platforms.sh <brief-path-or-empty> [<top-level-plan-path>] [<substrate-state-dir>]
#
#     <brief-path-or-empty>     A section brief / audit brief path,
#                               or "" to skip the section override
#                               (used by the onboarder, whose
#                               platform set is invariantly empty).
#     <top-level-plan-path>     Defaults to ./TOP-LEVEL-PLAN.md at
#                               the repo root.
#     <substrate-state-dir>     Defaults to ./.substrate-state at
#                               the repo root.
#
# Output (stdout): the resolved platform CSV. The empty string is a
# legitimate output ("no platforms; static template build").
#
# Exit codes:
#   0  resolved successfully; CSV on stdout
#   1  parse error in brief or TOP-LEVEL-PLAN.md, or subset violation

set -uo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    cat >&2 <<'EOF'
Usage: resolve-platforms.sh <brief-path-or-empty> [<top-level-plan-path>] [<substrate-state-dir>]

  <brief-path-or-empty>   section/audit brief; "" to skip section override
  <top-level-plan-path>   defaults to TOP-LEVEL-PLAN.md at the repo root
  <substrate-state-dir>   defaults to .substrate-state at the repo root

Emits resolved comma-separated platform CSV (may be empty) on stdout.
EOF
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

brief_path="$1"
tlp_path="${2:-${repo_root}/TOP-LEVEL-PLAN.md}"
state_dir="${3:-${repo_root}/.substrate-state}"
parser="${repo_root}/infra/scripts/lib/parse-platforms.sh"

log() { printf '[resolve-platforms] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Determine the project superset.
# ---------------------------------------------------------------------------
project_csv=""
project_source=""

if [ -f "${tlp_path}" ]; then
    if csv=$("${parser}" "${tlp_path}" "Platforms" 2>/dev/null); then
        project_csv="${csv}"
        project_source="TOP-LEVEL-PLAN.md"
    else
        rc=$?
        if [ "${rc}" -eq 10 ]; then
            : # marker absent; fall through to the next fallback
        elif [ "${rc}" -eq 1 ]; then
            "${parser}" "${tlp_path}" "Platforms" >/dev/null 2>&1 || true
            echo "resolve-platforms: TOP-LEVEL-PLAN.md '## Platforms' section is malformed (see error above)." >&2
            exit 1
        fi
    fi
fi

if [ -z "${project_source}" ] && [ -f "${state_dir}/platforms.txt" ]; then
    csv=""
    while IFS= read -r line; do
        line=$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "${line}" ] && continue
        [ "${line}" = "default" ] && continue
        if [ -z "${csv}" ]; then
            csv="${line}"
        else
            csv="${csv},${line}"
        fi
    done < "${state_dir}/platforms.txt"
    if [ -n "${csv}" ]; then
        project_csv="${csv}"
        project_source=".substrate-state/platforms.txt (s009 fallback)"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Determine the section override, if any.
# ---------------------------------------------------------------------------
section_csv=""
section_present=0

if [ -n "${brief_path}" ] && [ -f "${brief_path}" ]; then
    if csv=$("${parser}" "${brief_path}" "Required platforms" 2>/dev/null); then
        section_csv="${csv}"
        section_present=1
    else
        rc=$?
        if [ "${rc}" -eq 10 ]; then
            : # section silent — inherit project superset
        elif [ "${rc}" -eq 1 ]; then
            "${parser}" "${brief_path}" "Required platforms" >/dev/null 2>&1 || true
            echo "resolve-platforms: ${brief_path}: 'Required platforms' field is malformed (see error above)." >&2
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 3. Apply subset rule and pick the resolved set.
# ---------------------------------------------------------------------------
csv_to_set() {
    local csv="$1"
    [ -z "${csv}" ] && return 0
    printf '%s\n' "${csv}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | sort -u
}

if [ "${section_present}" -eq 1 ]; then
    if [ -n "${project_source}" ]; then
        # Verify section ⊆ project superset.
        mapfile -t section_arr < <(csv_to_set "${section_csv}")
        mapfile -t project_arr < <(csv_to_set "${project_csv}")
        violations=()
        for s in "${section_arr[@]:-}"; do
            [ -z "${s}" ] && continue
            # Strip version pin for the subset check — `python@3.11` is
            # a subset of project's `python` (or `python-extras`).
            sname="${s%%@*}"
            found=0
            for p in "${project_arr[@]:-}"; do
                [ -z "${p}" ] && continue
                pname="${p%%@*}"
                if [ "${sname}" = "${pname}" ]; then
                    found=1
                    break
                fi
            done
            if [ "${found}" -eq 0 ]; then
                violations+=("${s}")
            fi
        done
        if [ "${#violations[@]}" -gt 0 ]; then
            cat >&2 <<EOF

================================================================================
  PLATFORM SUBSET VIOLATION
================================================================================

  Section brief:     ${brief_path}
  Project superset:  ${project_csv} (from ${project_source})

  The section's "Required platforms" field declares platforms outside
  the project superset:

EOF
            for v in "${violations[@]}"; do
                printf '      - %s\n' "${v}" >&2
            done
            cat >&2 <<EOF

  Either:
    - Add the platform(s) to TOP-LEVEL-PLAN.md's "## Platforms" section
      (this is the project-wide declaration; architect-edited).
    - Remove the offending platform(s) from the section brief.

  The commission has NOT proceeded.
================================================================================

EOF
            exit 1
        fi
    fi
    resolved_csv="${section_csv}"
    log "resolved: ${resolved_csv:-(empty)} (from section brief)"
else
    resolved_csv="${project_csv}"
    if [ -n "${project_source}" ]; then
        log "resolved: ${resolved_csv:-(empty)} (from ${project_source}; section silent)"
    else
        log "resolved: (empty) (no project superset, no section override)"
    fi
fi

printf '%s\n' "${resolved_csv}"
