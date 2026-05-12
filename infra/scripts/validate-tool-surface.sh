#!/bin/bash
# infra/scripts/validate-tool-surface.sh — F52 closure (s013 / F50).
#
# At commission time, after compose-image.sh produces the role image,
# this validator verifies that every distinct binary named in the
# agent's parsed "Required tool surface" is reachable on PATH in the
# composed image. If any binary is named but missing, the commission
# fails loudly with an error listing the missing binaries and the
# platform set used.
#
# This catches the F52 class of bug: a brief grants `Bash(xxd:*)` or
# `Bash(pio test:*)` in the tool surface, but the platform set
# composed into the image doesn't actually ship that binary.
# Pre-F50, claude-code would attempt the call at agent runtime and
# either deny it silently or hit "command not found" — both opaque
# failure modes from the agent's perspective.
#
# Usage:
#   validate-tool-surface.sh <image-tag> <tool-surface-csv> [<platforms-csv>]
#
#   <image-tag>          A composed image tag — typically the stdout
#                        of compose-image.sh. The validator runs a
#                        one-shot `docker run --rm` against this tag.
#   <tool-surface-csv>   Comma-separated tool list — exactly the
#                        output of parse-tool-surface.sh against the
#                        section/audit brief. Non-Bash entries
#                        (Read, Edit, Write, Glob, etc.) are skipped
#                        since they are Claude built-ins, not OS
#                        binaries.
#   <platforms-csv>      Optional. The platform set composed into the
#                        image. Included in the error message for
#                        operator clarity ("you declared X, you got
#                        platforms Y, X needs binary Z which Y doesn't
#                        carry").
#
# Output: silent on success. On failure: a clear error block on
# stderr naming each missing binary, plus the image tag and platform
# set for context.
#
# Exit codes:
#   0  every Bash-referenced binary resolves on PATH in the image
#   1  one or more binaries are missing (commission must not proceed)
#   2  bad arguments / image not present locally / docker invocation
#      failure
#
# This validator is intentionally separate from s009's
# infra/scripts/lib/validate-platform.sh, which validates platform
# YAML schemas. The two have non-overlapping concerns (schema-of-
# registry vs binaries-of-image) and keep their distinct names per
# the s013 brief.

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    cat >&2 <<'EOF'
Usage: validate-tool-surface.sh <image-tag> <tool-surface-csv> [<platforms-csv>]

  <image-tag>          composed image tag (e.g. agent-coder-daemon-platforms:abc123)
  <tool-surface-csv>   parsed tool surface (output of parse-tool-surface.sh)
  <platforms-csv>      optional; included verbatim in any error message
EOF
    exit 2
fi

IMAGE_TAG="$1"
TOOLS_CSV="$2"
PLATFORMS_CSV="${3:-}"

log() { printf '[validate-tool-surface] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Verify the image exists locally. compose-image.sh's contract is
#    that the tag exists by the time it returns, so a missing tag here
#    means the caller skipped composition or the cache was cleared
#    between commission steps.
# ---------------------------------------------------------------------------
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    cat >&2 <<EOF
validate-tool-surface: image '${IMAGE_TAG}' is not present locally.

The caller should run compose-image.sh first and pass the resulting
tag. Re-running the commission should compose the image afresh.
EOF
    exit 2
fi

# ---------------------------------------------------------------------------
# 2. Extract distinct binaries from the tool surface. We only care
#    about Bash() patterns; non-Bash entries are Claude built-ins
#    (Read, Edit, Write, Glob, NotebookEdit, etc.) and have no OS
#    binary dependency.
#
#    Grammar accepted inside Bash(...):
#      Bash(<bin>)                  → bin
#      Bash(<bin>:*)                → bin
#      Bash(<bin> <arg1>...)        → bin
#      Bash(<bin> <flag> <subcmd>:*)→ bin  (e.g. `git -C /work log:*`)
#      Bash(<bin>:<subcmd>:*)       → bin  (alternate scoping form)
#
#    The "binary" is the first whitespace-or-colon-or-paren-or-flag
#    token after the open paren. We tolerate both forms (`git checkout`
#    and `git:checkout`) seen across existing briefs. A bare `Bash`
#    (no parens) means "any Bash" — represented by `bash` here, since
#    bash itself must be present in any agent image. (In practice the
#    role base layer guarantees bash; the check is cheap and
#    documents the requirement.)
#
#    Implementation note: we lowercase the leading word "bash" check
#    so `Bash`, `BASH`, and `bash` all parse uniformly.
# ---------------------------------------------------------------------------
extract_binaries() {
    # `printf '%s\n'` ensures a trailing newline so the final CSV
    # entry isn't silently dropped by `while read` (which only emits
    # records terminated by a newline). The leading sed normalises
    # any leftover \r on Windows-authored briefs.
    printf '%s\n' "${TOOLS_CSV}" | tr ',' '\n' | while IFS= read -r entry; do
        # Trim.
        entry=$(printf '%s' "${entry}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "${entry}" ] && continue
        # Drop the leading "Bash" (case-insensitive) and anything that
        # isn't a Bash pattern.
        head=$(printf '%s' "${entry}" | head -c 4 | tr '[:upper:]' '[:lower:]')
        if [ "${head}" != "bash" ]; then
            continue
        fi
        rest="${entry:4}"
        # rest is either "" (bare Bash) or "(...)" with optional ":*"
        # suffix outside the parens (no such cases observed in the
        # current spec but tolerated).
        rest=$(printf '%s' "${rest}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        if [ -z "${rest}" ]; then
            echo "bash"
            continue
        fi
        # Strip leading '(' and trailing ')'.
        inside="${rest#\(}"
        inside="${inside%\)}"
        # Inside may be empty (`Bash()` — degenerate, treat as bare).
        if [ -z "${inside}" ]; then
            echo "bash"
            continue
        fi
        # The binary is the first token before the first space, colon,
        # or end of string. tr the rest of the entry into spaces so
        # awk picks the first field cleanly.
        first=$(printf '%s' "${inside}" | awk '{
            # Replace ":" with space so the colon-suffix form
            # `git:checkout` yields "git" as $1. Same trick for "/"
            # — operators sometimes write Bash(./script.sh:*).
            gsub(":", " ", $0)
            print $1
        }')
        [ -z "${first}" ] && continue
        echo "${first}"
    done | sort -u
}

mapfile -t binaries < <(extract_binaries)

if [ "${#binaries[@]}" -eq 0 ]; then
    # No Bash-anchored binaries to check. (Tool surface might be
    # purely Read/Edit/Write.) Nothing to validate; success.
    log "no Bash-anchored binaries in tool surface; nothing to check"
    exit 0
fi

log "checking binaries against ${IMAGE_TAG}: ${binaries[*]}"

# ---------------------------------------------------------------------------
# 3. Run a single one-shot container that checks every binary at once.
#    Using --entrypoint bash to bypass the role's entrypoint (which
#    would clone repos, parse briefs, start the daemon, etc. — none
#    of which we want for a binary check).
#
#    The check emits "MISSING:<bin>" on stdout for each missing
#    binary, so the host side can collect them and produce a single
#    multi-binary error message.
# ---------------------------------------------------------------------------
docker_out=$(docker run --rm --entrypoint bash "${IMAGE_TAG}" -c '
    for b in "$@"; do
        if ! command -v "$b" >/dev/null 2>&1; then
            echo "MISSING:$b"
        fi
    done
' _ "${binaries[@]}" 2>&1) || {
    cat >&2 <<EOF
validate-tool-surface: docker run failed against ${IMAGE_TAG}.

Output:
${docker_out}
EOF
    exit 2
}

missing=()
while IFS= read -r line; do
    case "${line}" in
        MISSING:*) missing+=("${line#MISSING:}") ;;
    esac
done <<<"${docker_out}"

if [ "${#missing[@]}" -eq 0 ]; then
    log "all ${#binaries[@]} binaries resolve on PATH"
    exit 0
fi

cat >&2 <<EOF

================================================================================
  TOOL SURFACE VALIDATION FAILED
================================================================================

  Image:      ${IMAGE_TAG}
  Platforms:  ${PLATFORMS_CSV:-(none / default)}

  The following binaries are named in the agent's "Required tool surface"
  but are not present on PATH in the composed image:

EOF
for b in "${missing[@]}"; do
    printf '      - %s\n' "${b}" >&2
done

cat >&2 <<EOF

  Either:
    - The brief's tool surface lists a binary that isn't needed; remove it.
    - The section needs a platform that supplies the binary; declare it in
      the brief's "Required platforms" field (or in TOP-LEVEL-PLAN.md's
      "## Platforms" section as a project-wide platform).
    - The platform that does supply the binary isn't installing it; check
      methodology/platforms/<platform>.yaml for the role's install/apt
      block.

  The commission has NOT proceeded — re-author the brief and re-commission.
================================================================================

EOF
exit 1
