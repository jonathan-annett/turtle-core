#!/bin/bash
# infra/scripts/lib/parse-platforms.sh — F50 / s013 helper.
#
# Parses a "Required platforms" field (section brief) or a "Platforms"
# section (TOP-LEVEL-PLAN.md) and emits a comma-separated platform
# list suitable for passing into compose-image.sh.
#
# Modelled on infra/scripts/lib/parse-tool-surface.sh — same fenced-
# code-block grammar, same dual bullet/heading marker forms, same
# multi-mode exit codes — but parameterised by the marker name so
# the same parser handles both the section brief's "Required
# platforms" field and TOP-LEVEL-PLAN.md's "Platforms" project
# superset declaration.
#
# Usage:
#   parse-platforms.sh <file-path> <marker>
#
#     <file-path>   Path to the brief or TOP-LEVEL-PLAN.md.
#     <marker>      Field name to scan for, case-insensitive.
#                   Typical values: "Required platforms" |
#                   "Platforms".
#
# Output (stdout): comma-separated platform names on success. The
#   list may be empty (CSV is the empty string) if the field exists
#   but explicitly declares no platforms — that's a valid section
#   declaration meaning "this section needs no platform layers".
#
# Exit codes:
#   0   field parsed successfully; CSV on stdout
#   1   file exists but field is present-but-malformed (no fence,
#       unterminated fence, non-list contents)
#   2   bad argument
#   10  field is absent — caller treats this as "fall back to project
#       superset / s009 substrate state" depending on context
#
# Accepted marker forms in the file:
#   - bullet:  "- **<Marker>[.:]?**"     followed by a fenced block
#   - heading: "## <Marker>" (h2..h6)    followed by a fenced block
#
# Inside the fence: a YAML simple list (`- node-extras`, one per
# line; `#` comments and blank lines are skipped) or a JSON array
# (`["node-extras", "python-extras"]`). Bare names and `name@version`
# pinned forms are both accepted — compose-image.sh sees the raw
# string for each entry and the registry's content-hash mechanism
# does the right thing.

set -uo pipefail

if [ "$#" -ne 2 ]; then
    echo "parse-platforms: usage: $0 <file-path> <marker>" >&2
    exit 2
fi

file_path="$1"
marker="$2"

if [ -z "${file_path}" ] || [ -z "${marker}" ]; then
    echo "parse-platforms: <file-path> and <marker> must be non-empty" >&2
    exit 2
fi

if [ ! -f "${file_path}" ]; then
    echo "parse-platforms: file not found at ${file_path}" >&2
    exit 2
fi

# Lowercase the marker once so awk's literal-string match is case-
# insensitive without depending on mawk's regex-flag support.
marker_lower=$(printf '%s' "${marker}" | tr '[:upper:]' '[:lower:]')

# Extract the body lines inside the first fenced block after the
# marker. The awk exit codes distinguish failure modes the caller may
# need to report distinctly (especially "marker not found", which is
# the "field absent → fall back" signal).
body=$(MARKER_LOWER="${marker_lower}" awk '
    BEGIN {
        marker = ENVIRON["MARKER_LOWER"]
        state  = "search"
        found  = 0
        body_started = 0
    }

    # search: looking for the marker. Both bullet and heading shapes.
    state == "search" {
        lower = tolower($0)
        # Bullet form: "- **<marker>[.:]?**"
        bullet_pat = "^[[:space:]]*-[[:space:]]+\\*\\*" marker "[.:]?\\*\\*"
        if (lower ~ bullet_pat) {
            state = "post-marker"; found = 1; next
        }
        # Heading form: "## <marker>" through "###### <marker>"
        heading_pat = "^[[:space:]]*##+[[:space:]]+" marker "[[:space:]]*$"
        if (lower ~ heading_pat) {
            state = "post-marker"; found = 1; next
        }
        next
    }

    # post-marker: scan for an opening fence; bail out if we hit the
    # next field marker or top-level heading first.
    state == "post-marker" {
        if ($0 ~ /^[[:space:]]*-[[:space:]]+\*\*[A-Z][^*]*\*\*/) { state = "no-fence"; exit }
        if ($0 ~ /^[[:space:]]*##?[[:space:]]+/)                 { state = "no-fence"; exit }
        if ($0 ~ /^[[:space:]]*```/) { state = "in-fence"; next }
        next
    }

    # in-fence: collect body lines until the closing fence.
    state == "in-fence" {
        if ($0 ~ /^[[:space:]]*```[[:space:]]*$/) { state = "done"; exit }
        print
        body_started = 1
    }

    END {
        if (!found)                                 { exit 10 }
        if (state == "post-marker" || state == "no-fence") { exit 11 }
        if (state == "in-fence")                    { exit 12 }
        if (state == "done" && !body_started)       { exit 13 }
    }
' "${file_path}")
awk_rc=$?

case "${awk_rc}" in
    0) ;;
    10) exit 10 ;;
    11) echo "parse-platforms: ${file_path}: '${marker}' marker has no fenced code block before the next field/heading." >&2; exit 1 ;;
    12) echo "parse-platforms: ${file_path}: '${marker}' code block is unterminated (missing closing \`\`\`)." >&2; exit 1 ;;
    13)
        # Empty fence is a valid declaration: "no platforms required".
        printf ''
        exit 0
        ;;
    *) echo "parse-platforms: awk failed (${awk_rc}) parsing ${file_path}" >&2; exit 1 ;;
esac

# Trim each line, drop blanks.
trimmed=$(printf '%s\n' "${body}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true)

if [ -z "${trimmed}" ]; then
    # Body was only comments / whitespace → same as empty declaration.
    printf ''
    exit 0
fi

# Decide JSON vs YAML on the first non-comment character.
first_char=$(printf '%s' "${trimmed}" | grep -v '^#' | head -c1 || true)

if [ "${first_char}" = "[" ]; then
    platforms=$(printf '%s\n' "${trimmed}" | jq -r 'if type=="array" then .[] else error("not an array") end' 2>/dev/null) || {
        echo "parse-platforms: ${file_path}: '${marker}' JSON body is not a valid array." >&2
        exit 1
    }
else
    # YAML simple list: each remaining line must be `- <item>` or `#`
    # comment.
    parse_err=$(printf '%s\n' "${trimmed}" | awk '
        /^#/ { next }
        /^-[[:space:]]+/ {
            sub(/^-[[:space:]]+/, "")
            print
            next
        }
        { print "ERR:" $0 > "/dev/stderr"; bad = 1 }
        END { if (bad) exit 1 }
    ' 2>&1 >/tmp/.parse-platforms-$$)
    awk2_rc=$?
    platforms=$(cat /tmp/.parse-platforms-$$ 2>/dev/null || true)
    rm -f /tmp/.parse-platforms-$$
    if [ "${awk2_rc}" -ne 0 ]; then
        bad_line=$(printf '%s' "${parse_err}" | head -n1 | sed 's/^ERR://')
        echo "parse-platforms: ${file_path}: '${marker}' YAML entry not in '- item' form: ${bad_line}" >&2
        exit 1
    fi
fi

# Join into a CSV. Empty entries skipped; whitespace trimmed.
out=""
while IFS= read -r p; do
    p=$(printf '%s' "${p}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -z "${p}" ] && continue
    if [ -z "${out}" ]; then
        out="${p}"
    else
        out="${out},${p}"
    fi
done <<<"${platforms}"

printf '%s\n' "${out}"
