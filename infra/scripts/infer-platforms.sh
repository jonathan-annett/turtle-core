#!/bin/bash
# infra/scripts/infer-platforms.sh
#
# Infers the platform set from canonical signal files at the brownfield
# source root. Used by ./onboard-project.sh during the onboarder's
# phase-1 setup to propose a "Required platforms" set for the migration
# brief; the operator confirms or corrects during elicitation.
#
# Inference is heuristic and intentionally conservative — false negatives
# (missing a platform that's there) are recoverable via the elicitation
# pass or the --platforms=<csv> override on ./onboard-project.sh; false
# positives (proposing a platform the project doesn't need) waste a
# composition cycle but are otherwise harmless.
#
# Signals detected (canonical project-root markers; subdirs are NOT
# walked — we trust the root layout over scattered tooling files in
# vendored upstreams or test fixtures):
#
#   package.json                    → node-extras
#   requirements.txt                → python-extras
#   pyproject.toml                  → python-extras
#   setup.py                        → python-extras
#   Cargo.toml                      → rust
#   go.mod                          → go
#   platformio.ini                  → platformio-esp32
#   CMakeLists.txt / Makefile *     → c-cpp
#   (Makefile only if no other signal — a project may have a Makefile
#   that wraps non-C build steps; we treat it as c-cpp only when it
#   stands alone.)
#
# Usage:
#   infer-platforms.sh <source-dir>
#
# Output (stdout): comma-separated platform CSV (may be empty).
# Exit codes:
#   0  inferred (possibly empty)
#   1  bad arguments / missing source dir

set -uo pipefail

if [ "$#" -ne 1 ]; then
    cat >&2 <<'EOF'
Usage: infer-platforms.sh <source-dir>

Emits a comma-separated platform CSV inferred from canonical signal
files at the project root. Empty output is legitimate ("no detectable
platforms; operator should confirm or supply via --platforms").
EOF
    exit 1
fi

src="$1"
if [ ! -d "${src}" ]; then
    echo "infer-platforms.sh: not a directory: ${src}" >&2
    exit 1
fi

inferred=()

# Track each detection so an order-independent "seen" check is cheap.
seen() {
    local needle="$1"
    local p
    for p in "${inferred[@]:-}"; do
        [ "${p}" = "${needle}" ] && return 0
    done
    return 1
}

add() {
    if ! seen "$1"; then
        inferred+=("$1")
    fi
}

# Order: most specific signals first; the c-cpp Makefile fallback runs
# last so we don't double-count a project that has both a Makefile and
# a language-specific manifest.
if [ -f "${src}/package.json" ]; then
    add "node-extras"
fi
if [ -f "${src}/requirements.txt" ] || [ -f "${src}/pyproject.toml" ] || [ -f "${src}/setup.py" ]; then
    add "python-extras"
fi
if [ -f "${src}/Cargo.toml" ]; then
    add "rust"
fi
if [ -f "${src}/go.mod" ]; then
    add "go"
fi
if [ -f "${src}/platformio.ini" ]; then
    add "platformio-esp32"
fi
if [ -f "${src}/CMakeLists.txt" ]; then
    add "c-cpp"
elif [ -f "${src}/Makefile" ] && [ "${#inferred[@]}" -eq 0 ]; then
    # Standalone Makefile (no language manifest) — most likely C/C++.
    # If other signals already triggered, the Makefile is probably a
    # wrapper for them, not a c-cpp build.
    add "c-cpp"
fi

# Emit CSV. Empty array → empty string (a legitimate output).
csv=""
for p in "${inferred[@]:-}"; do
    [ -z "${p}" ] && continue
    if [ -z "${csv}" ]; then
        csv="${p}"
    else
        csv="${csv},${p}"
    fi
done
printf '%s\n' "${csv}"
