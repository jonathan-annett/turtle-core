#!/bin/bash
# infra/scripts/dispatch-code-migration.sh
#
# Dispatches the code migration agent during brownfield onboarding (s014
# Section B). Called by ./onboard-project.sh between the onboarder's
# "write migration brief" phase and its "synthesise handover" phase:
#
#   1. The onboarder, in interactive elicitation, has authored
#      briefs/onboarding/code-migration.brief.md and pushed it to main.
#   2. This helper runs (host-side): resolves platforms from the brief,
#      composes a hash-tagged agent image with those platforms,
#      validates the brief's "Required tool surface" against the
#      composed image, runs the agent container with the appropriate
#      mounts, and blocks until the agent commits its report and
#      discharges.
#   3. ./onboard-project.sh then re-invokes the onboarder against the
#      committed report, with a phase-2 prompt directing findings
#      synthesis into the handover.
#
# Override-during-implementation note (s013 pattern): the section B
# brief's B.6 says "the dispatch call" sits inside the onboarder's
# entrypoint. The clean alternative is to keep dispatch host-side
# (mirroring audit.sh / commission-pair.sh, all host-orchestrated) and
# let ./onboard-project.sh drive the multi-phase flow. This avoids
# mounting /var/run/docker.sock into the onboarder container — a real
# privilege elevation we don't otherwise need. The section report
# records this deviation explicitly.
#
# Usage:
#   dispatch-code-migration.sh [--source-path <host-path>]
#
#     --source-path <host-path>    Optional: override the host-side path
#                                  to the brownfield source materials.
#                                  Defaults to SOURCE_PATH env (set by
#                                  ./onboard-project.sh) or fails if
#                                  neither is provided.
#
# Inputs (env, set by ./onboard-project.sh):
#   SOURCE_PATH                  Absolute host path to /source mount.
#                                Required. The --source-path flag
#                                overrides this.
#   ARCHITECT_CONTAINER          Default agent-architect (for brief
#                                existence checks; same pattern as
#                                check-brief.sh).
#   GIT_SERVER_CONTAINER         Default agent-git-server.
#   DISPATCH_COMPOSE_PROJECT     Default <repo-basename>-code-migration.
#
# Outputs:
#   Logs to stderr ("[dispatch] ..."). Exit 0 on success (agent
#   committed report). Non-zero on failure with a diagnostic.
#
# Exit codes:
#   0   agent dispatched, report committed
#   1   substrate not up, missing brief, parse/validate failure
#   2   bad arguments
#   3   agent container exited non-zero (dispatch ran but agent failed
#       to produce a report)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

# shellcheck source=infra/scripts/lib/check-brief.sh
source "${repo_root}/infra/scripts/lib/check-brief.sh"

log() { printf '[dispatch] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
source_path_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
        --source-path)
            [ $# -ge 2 ] || { echo "dispatch-code-migration.sh: --source-path needs an argument" >&2; exit 2; }
            source_path_override="$2"; shift 2 ;;
        --source-path=*)
            source_path_override="${1#--source-path=}"; shift ;;
        --*)
            echo "dispatch-code-migration.sh: unknown flag: $1" >&2
            exit 2 ;;
        *)
            echo "dispatch-code-migration.sh: unexpected argument: $1" >&2
            exit 2 ;;
    esac
done

source_path="${source_path_override:-${SOURCE_PATH:-}}"
if [ -z "${source_path}" ]; then
    cat >&2 <<'EOF'
dispatch-code-migration.sh: source path is required.

Either set SOURCE_PATH in env (./onboard-project.sh does this) or pass
--source-path=<host-path>. The agent's container mounts this path at
/source read-only; it must be the brownfield project tree the
onboarder synthesised against.
EOF
    exit 2
fi
if [ ! -d "${source_path}" ]; then
    echo "dispatch-code-migration.sh: source path is not a directory: ${source_path}" >&2
    exit 2
fi
source_path_abs="$(cd "${source_path}" && pwd)"

# ---------------------------------------------------------------------------
# Substrate-up check. We need git-server (so the agent can clone main)
# and the architect (so the brief-existence check can use its /work
# clone, same pattern as audit.sh / commission-pair.sh).
# ---------------------------------------------------------------------------
arch_container="${ARCHITECT_CONTAINER:-agent-architect}"
git_container="${GIT_SERVER_CONTAINER:-agent-git-server}"

is_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

for c in "${git_container}" "${arch_container}"; do
    if ! is_running "${c}"; then
        cat >&2 <<EOF
dispatch-code-migration.sh: ${c} container is not running.

The substrate must be up before dispatching the code-migration agent.
Bring it up first:

    ./setup-linux.sh    # or ./setup-mac.sh
EOF
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Brief existence check. The migration brief must already be committed
# to main (the onboarder pushes it during phase 1 of the onboarding flow).
# ---------------------------------------------------------------------------
brief_path="briefs/onboarding/code-migration.brief.md"
log "verifying migration brief exists on main..."
if ! check_brief_exists "${brief_path}"; then
    cat >&2 <<EOF

dispatch-code-migration.sh: the migration brief was not found on main.

The onboarder authors briefs/onboarding/code-migration.brief.md during
its phase-1 interactive elicitation. If that phase did not complete (or
the brief was not committed and pushed), dispatch cannot proceed.

Re-enter the onboarder via ./onboard-project.sh and ensure the brief
lands on main before dispatching this helper.
EOF
    exit 1
fi

# Resolve the brief's host-side path for parsing. The architect's /work
# clone is the canonical surface (same as check-brief.sh), but we need
# the brief's content host-side to run resolve-platforms.sh and
# parse-tool-surface.sh against it. Fetch the file out of the
# architect's clone via docker exec; tee to a tempfile so subsequent
# parsers have a stable host path.
brief_host=$(mktemp)
trap 'rm -f "${brief_host}"' EXIT
if ! docker exec "${arch_container}" cat "/work/${brief_path}" > "${brief_host}" 2>/dev/null; then
    echo "dispatch-code-migration.sh: failed to read /work/${brief_path} from ${arch_container}" >&2
    exit 1
fi
if [ ! -s "${brief_host}" ]; then
    echo "dispatch-code-migration.sh: /work/${brief_path} in ${arch_container} is empty" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Platform resolution.
#
# Unlike planner/auditor (resolve-platforms.sh with project-superset
# subset semantics), the migration brief is authored BEFORE
# TOP-LEVEL-PLAN.md exists — the architect drafts that on first attach,
# after the onboarder has discharged. There is no project superset to
# subset against yet. The migration brief's "Required platforms" field
# is therefore authoritative on its own; we parse it directly via
# parse-platforms.sh and use the result as the resolved set.
#
# The onboarder either inferred this set from /source signals (per
# design call 1) or received it from the operator via
# `./onboard-project.sh --platforms=<csv>` (design call 2).
# ---------------------------------------------------------------------------
log "parsing Required platforms from migration brief..."
parse_platforms="${repo_root}/infra/scripts/lib/parse-platforms.sh"
if platforms_csv=$("${parse_platforms}" "${brief_host}" "Required platforms" 2>/dev/null); then
    log "platforms: ${platforms_csv:-(none)}"
else
    rc=$?
    if [ "${rc}" -eq 10 ]; then
        # Marker absent — treat as empty (static template build).
        platforms_csv=""
        log "platforms: (none — 'Required platforms' field absent; static template build)"
    else
        # Re-run to surface the parser's stderr.
        "${parse_platforms}" "${brief_host}" "Required platforms" >/dev/null 2>&1 || true
        echo "dispatch-code-migration.sh: migration brief 'Required platforms' field is malformed (see error above)." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Image composition (s013 F50).
# ---------------------------------------------------------------------------
log "composing code-migration image..."
if ! agent_image=$("${repo_root}/infra/scripts/compose-image.sh" code-migration "${platforms_csv}"); then
    echo "dispatch-code-migration.sh: FATAL — code-migration image composition failed." >&2
    exit 1
fi
log "composed image: ${agent_image}"

# ---------------------------------------------------------------------------
# Tool-surface validation (s013 F52 closure).
# ---------------------------------------------------------------------------
log "parsing Required tool surface from migration brief..."
parse_tool="${repo_root}/infra/scripts/lib/parse-tool-surface.sh"
if ! tools_csv=$("${parse_tool}" "${brief_host}"); then
    cat >&2 <<EOF

dispatch-code-migration.sh: FATAL — could not parse 'Required tool
surface' from the migration brief. See the parser error above.

The onboarder must author this field per
methodology/code-migration-brief-template.md before dispatch can
proceed. Without it, every survey probe the agent runs would be
silently denied by claude.
EOF
    exit 1
fi
log "tool surface: ${tools_csv}"

log "validating composed image against tool surface..."
if ! "${repo_root}/infra/scripts/validate-tool-surface.sh" "${agent_image}" "${tools_csv}" "${platforms_csv}"; then
    echo "dispatch-code-migration.sh: FATAL — tool-surface validation failed (see error above)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Bootstrap prompt.
#
# The canonical code-migration bootstrap prompt (becomes a methodology
# reference, parallel to s008's planner/auditor prompts and s012's
# onboarder prompt). Encodes:
#   - Read the migration brief at the canonical path.
#   - Read the agent guide (symlinked as /work/CLAUDE.md by the
#     container entrypoint).
#   - Read /source (read-only) and survey per the brief.
#   - Produce the report at the canonical path; commit with the
#     exact message expected by the onboarder's synthesis pass.
# ---------------------------------------------------------------------------
bootstrap_prompt="Read /work/${brief_path}, which is your migration brief. Read /methodology/code-migration-agent-guide.md (symlinked as /work/CLAUDE.md) and /methodology/code-migration-report-template.md for your operating boundaries and report shape. The brownfield source materials are at /source (read-only). Perform structural review per the brief — survey, do not build or run the project. Produce the migration report at /work/briefs/onboarding/code-migration.report.md following the six-section structure in the template. When the report is complete, commit with the exact message 'onboarding: code-migration report', push to origin main, and discharge."

# ---------------------------------------------------------------------------
# Compose-project naming + cleanup.
# ---------------------------------------------------------------------------
project_base="$(basename "${repo_root}")"
project="${DISPATCH_COMPOSE_PROJECT:-${project_base}-code-migration}"

cleanup() {
    rc=$?
    echo
    log "tearing down code-migration container (project=${project})..."
    docker compose -p "${project}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' >&2 || true
    rm -f "${brief_host}"
    exit "${rc}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Bring the agent up. SOURCE_PATH + ANTHROPIC_API_KEY come from env; the
# compose service definition (B.4) reads SOURCE_PATH at substitution
# time. BRIEF_PATH is passed through to the entrypoint so the
# parse-tool-surface.sh invocation can find the brief without
# heuristics. CODE_MIGRATION_IMAGE pins the JIT-composed image.
# ---------------------------------------------------------------------------
log "commissioning code-migration agent (project=${project})..."
echo >&2

set +e
SOURCE_PATH="${source_path_abs}" \
CODE_MIGRATION_IMAGE="${agent_image}" \
BOOTSTRAP_PROMPT="${bootstrap_prompt}" \
BRIEF_PATH="/work/${brief_path}" \
    docker compose -p "${project}" --profile ephemeral run --rm \
        -e BOOTSTRAP_PROMPT \
        -e BRIEF_PATH \
        code-migration
agent_rc=$?
set -e

if [ "${agent_rc}" -ne 0 ]; then
    cat >&2 <<EOF

dispatch-code-migration.sh: agent container exited non-zero (rc=${agent_rc}).

The container's entrypoint should keep the shell reachable for
post-mortem inspection even on claude failure. If the agent did not
commit the migration report, the onboarder's phase-2 synthesis will
fail to find it.
EOF
    exit 3
fi

# Confirm the report was committed (defence in depth — the git-server
# update hook should reject any push that doesn't touch the canonical
# report path, but verifying directly is cheap).
report_path="briefs/onboarding/code-migration.report.md"
if ! docker exec "${arch_container}" git -C /work fetch -q origin main 2>/dev/null; then
    log "WARNING: could not fetch origin/main from ${arch_container}; skipping report-existence verification."
elif ! docker exec "${arch_container}" git -C /work cat-file -e "origin/main:${report_path}" 2>/dev/null; then
    cat >&2 <<EOF

dispatch-code-migration.sh: agent discharged but ${report_path} was
not found on origin/main. The agent may have exited before committing,
or the commit may not have pushed cleanly.
EOF
    exit 3
fi

log "code-migration agent discharged; report committed at ${report_path}."
