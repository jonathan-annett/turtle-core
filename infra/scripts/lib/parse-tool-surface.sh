#!/bin/bash
# parse-tool-surface.sh — bash port of infra/coder-daemon/parse-tool-surface.js
# for the planner and auditor entrypoints (spec §7.2, §7.6). Same input
# shape, same failure semantics, so all three role-pair handoffs use the
# same brief-side schema.
#
# Usage:
#   parse-tool-surface.sh <brief-path>
# Output:
#   - Comma-separated tool list on stdout (suitable for `--allowed-tools`).
#   - Empty stdout + non-zero exit + actionable error on stderr on any
#     failure: missing brief, no marker, no fence, malformed body, empty
#     list. The exit code is always 1 for parse failures (the caller does
#     not need to distinguish the cause; the stderr message is enough).
#
# Accepts both forms documented in spec §7.3 (and now §7.2 / §7.6):
#   - bullet:  "- **Required tool surface[.:]?**" followed by a fenced
#     code block on subsequent lines.
#   - heading: "## Required tool surface" (h2..h6) followed by a fenced
#     code block (possibly with intervening prose).
# Inside the fence: either a JSON array (`[ "Read", ... ]`) or a simple
# YAML list (`- Read` per line; `#` comments and blank lines are skipped).

set -uo pipefail

brief_path="${1:-}"
if [ -z "${brief_path}" ]; then
    echo "tool-surface: usage: $0 <brief-path>" >&2
    exit 2
fi
if [ ! -f "${brief_path}" ]; then
    echo "tool-surface: brief not found at ${brief_path}" >&2
    exit 1
fi

# Extract the body lines that lie inside the first fenced code block after
# the field marker, before any subsequent field marker or top-level
# heading. awk emits the body verbatim on stdout. The awk exit code
# distinguishes the failure modes so the caller can produce a precise
# error.
body=$(awk '
    BEGIN {
        state         = "search"   # search | post-marker | in-fence | done
        found_marker  = 0
        body_started  = 0
    }

    # search: looking for the field marker (bullet or heading form). POSIX
    # awk has no case-insensitive regex flag; use tolower() instead. mawk
    # (Debian default) does not support `{n,m}` regex quantifiers, so we
    # use `##+` (two-or-more `#`s) for h2-or-deeper headings.
    state == "search" {
        lower = tolower($0)
        if (lower ~ /^[[:space:]]*-[[:space:]]+\*\*required tool surface[.:]?\*\*/ ||
            lower ~ /^[[:space:]]*##+[[:space:]]+required tool surface[[:space:]]*$/) {
            state = "post-marker"
            found_marker = 1
            next
        }
        next
    }

    # post-marker: scan forward for an opening fence; bail out if we hit
    # the next field marker or top-level heading first (the field has
    # ended without a code block). `##?` matches h1 or h2 only — deeper
    # headings inside the field are allowed.
    state == "post-marker" {
        if ($0 ~ /^[[:space:]]*-[[:space:]]+\*\*[A-Z][^*]*\*\*/) { state = "no-fence"; exit }
        if ($0 ~ /^[[:space:]]*##?[[:space:]]+/)                 { state = "no-fence"; exit }
        if ($0 ~ /^[[:space:]]*```/) {
            state = "in-fence"
            next
        }
        next
    }

    # in-fence: collect body lines until the closing fence.
    state == "in-fence" {
        if ($0 ~ /^[[:space:]]*```[[:space:]]*$/) {
            state = "done"
            exit
        }
        print
        body_started = 1
    }

    END {
        if (!found_marker)            { exit 10 }   # no marker
        if (state == "post-marker")   { exit 11 }   # no fence after marker
        if (state == "in-fence")      { exit 12 }   # unterminated fence
        if (state == "no-fence")      { exit 11 }   # field terminated without a fence
        if (state == "done" && !body_started) { exit 13 } # empty fence
    }
' "${brief_path}")
awk_rc=$?

case "${awk_rc}" in
    0) ;;
    10) echo "tool-surface: brief at ${brief_path} has no 'Required tool surface' field. The architect must author this field; see methodology/agent-orchestration-spec.md §7.2 (section briefs) or §7.6 (audit briefs)." >&2; exit 1 ;;
    11) echo "tool-surface: brief at ${brief_path} has a 'Required tool surface' marker but no fenced code block follows it before the next field." >&2; exit 1 ;;
    12) echo "tool-surface: brief at ${brief_path} 'Required tool surface' code block is unterminated (missing closing \`\`\`)." >&2; exit 1 ;;
    13) echo "tool-surface: brief at ${brief_path} 'Required tool surface' code block is empty." >&2; exit 1 ;;
    *)  echo "tool-surface: awk failed (${awk_rc}) parsing ${brief_path}" >&2; exit 1 ;;
esac

# Trim leading/trailing whitespace per line, drop fully-blank lines.
trimmed=$(printf '%s\n' "${body}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)

if [ -z "${trimmed}" ]; then
    echo "tool-surface: brief at ${brief_path} 'Required tool surface' code block is empty after trim." >&2
    exit 1
fi

# Decide between JSON and YAML forms by inspecting the first non-empty,
# non-comment character. JSON starts with '['; anything else is treated
# as the YAML simple-list form.
first_char=$(printf '%s' "${trimmed}" | grep -v '^#' | head -c1 || true)

if [ "${first_char}" = "[" ]; then
    # Parse via jq. The whole trimmed body is the JSON array (multi-line
    # arrays are valid JSON).
    tools=$(printf '%s\n' "${trimmed}" | jq -r 'if type=="array" then .[] else error("not an array") end' 2>/dev/null)
    if [ -z "${tools}" ]; then
        echo "tool-surface: brief at ${brief_path} 'Required tool surface' code block is not valid JSON or is empty." >&2
        exit 1
    fi
else
    # YAML simple-list form. Each remaining line must be `- <item>`; lines
    # starting with `#` are comments and skipped. Anything else fails.
    parse_err=$(printf '%s\n' "${trimmed}" | awk '
        /^#/ { next }
        /^-[[:space:]]+/ {
            sub(/^-[[:space:]]+/, "")
            print
            next
        }
        { print "ERR:" $0 > "/dev/stderr"; bad=1 }
        END { if (bad) exit 1 }
    ' 2>&1 >/tmp/.tool-surface-$$ )
    awk2_rc=$?
    tools=$(cat /tmp/.tool-surface-$$ 2>/dev/null || true)
    rm -f /tmp/.tool-surface-$$
    if [ "${awk2_rc}" -ne 0 ]; then
        bad_line=$(printf '%s' "${parse_err}" | head -n1 | sed 's/^ERR://')
        echo "tool-surface: brief at ${brief_path} 'Required tool surface' YAML entry not in '- item' form: ${bad_line}" >&2
        exit 1
    fi
fi

# Final validation: at least one tool, each non-empty after trim.
out=""
while IFS= read -r tool; do
    tool=$(printf '%s' "${tool}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "${tool}" ] && continue
    if [ -z "${out}" ]; then
        out="${tool}"
    else
        out="${out},${tool}"
    fi
done <<<"${tools}"

if [ -z "${out}" ]; then
    echo "tool-surface: brief at ${brief_path} 'Required tool surface' list is empty after parsing." >&2
    exit 1
fi

printf '%s\n' "${out}"
