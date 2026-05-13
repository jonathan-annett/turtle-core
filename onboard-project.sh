#!/bin/bash
# onboard-project.sh <source-path> [--type 1|2|3|4] [--intake-file <path>]
#                                  [--platforms <csv>]
#
# Operator-facing entry point for the onboarder. Mints the brownfield
# project's main.git on the substrate's git-server, imports the source
# tree as the initial commit, then drives a three-phase onboarding:
#
#   Phase 1 (s012): the onboarder elicits operator priorities and
#                   unknowns interactively, confirms or corrects the
#                   inferred platform set, writes the migration brief
#                   for the code migration agent, and writes a draft
#                   handover at briefs/onboarding/handover.draft.md
#                   with section 3 (code structural review) left as a
#                   TODO placeholder. Onboarder discharges.
#
#   Phase 2 (s014): the host dispatches the code migration agent via
#                   infra/scripts/dispatch-code-migration.sh. The agent
#                   reads its commissioning brief, performs structural
#                   survey on /source, and commits the migration
#                   report. No operator interaction during this phase.
#
#   Phase 3 (s014): the onboarder re-runs against the migration report
#                   and the draft handover. It integrates the report's
#                   findings into section 3, writes the final handover
#                   at briefs/onboarding/handover.md, and discharges.
#                   The architect's first-attach detection keys on this
#                   final file.
#
# Single-shot: refuses to run a second time for the same project
# (enforced by inspecting the bare main.git on the git-server).
#
# Sibling of ./commission-pair.sh and ./audit.sh.
#
# Args:
#   <source-path>           Directory containing the brownfield project.
#                           Mounted into the onboarder and the code
#                           migration agent read-only at /source.
#                           Required.
#   --type 1|2|3|4          Optional project-type hint (see the four-type
#                           taxonomy in methodology/onboarder-guide.md §4).
#                           If omitted, the onboarder infers / elicits.
#   --intake-file <path>    Optional file with operator-supplied initial
#                           context (notes, priorities, links). Mounted
#                           into the onboarder at /onboarding-intake.md.
#   --platforms <csv>       Optional comma-separated platform list (e.g.
#                           "python-extras,node-extras"). When supplied,
#                           skips platform inference and uses exactly
#                           this set in the migration brief. Power-user
#                           fast path; default is inference + operator
#                           confirmation during phase-1 elicitation.
#                           Independent of --type: --type taxonomises
#                           the source-material kind (code only / +notes
#                           / +history / +methodology); --platforms
#                           declares target-language toolchains.
#
# Env overrides (test fixture surface; production callers leave unset):
#   ARCHITECT_CONTAINER     Default agent-architect.
#   GIT_SERVER_CONTAINER    Default agent-git-server.
#   ONBOARD_COMPOSE_PROJECT Default <repo-basename>-onboard.
#   DISPATCH_COMPOSE_PROJECT  Default <repo-basename>-code-migration.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: ./onboard-project.sh <source-path> [--type 1|2|3|4] [--intake-file <path>]
                            [--platforms <csv>]

  <source-path>         Directory containing the brownfield project. Mounted
                        read-only into the onboarder and the code migration
                        agent at /source.

  --type 1|2|3|4        Optional project-type hint. The onboarder infers
                        from /source if you omit this; pass it when the
                        type is unambiguous and you want to skip that step.
                        Type taxonomises the source-material kind (1 code
                        only / 2 +notes / 3 +history / 4 +methodology).
                        Independent of --platforms.

  --intake-file <path>  Optional markdown file with your initial framing
                        (goals, priorities, hard constraints, things you
                        want the architect to know on day one). Mounted at
                        /onboarding-intake.md inside the onboarder.

  --platforms <csv>     Optional comma-separated platform list (e.g.
                        "python-extras,node-extras"). When supplied, skips
                        platform inference and uses exactly this set in
                        the migration brief commissioned to the code
                        migration agent. Power-user fast path; default is
                        inference from canonical signal files at the
                        source root, followed by operator confirmation
                        during phase-1 elicitation. Independent of --type.

  -h, --help            Show this help.

The project's main.git on the substrate's git-server must be empty (only
the initial empty commit from setup). The script refuses to run otherwise;
onboarding is single-shot per project.

Example:
    ./onboard-project.sh ~/code/legacy-thing --type 2 --intake-file ~/onboarding-notes.md
    ./onboard-project.sh ~/code/polyglot-thing --platforms python-extras,node-extras
EOF
}

source_path=""
type_hint="unknown"
intake_file=""
platforms_override=""
platforms_override_present=0

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --type)
            [ $# -ge 2 ] || { echo "onboard-project.sh: --type needs an argument" >&2; exit 2; }
            type_hint="$2"; shift 2 ;;
        --type=*) type_hint="${1#--type=}"; shift ;;
        --intake-file)
            [ $# -ge 2 ] || { echo "onboard-project.sh: --intake-file needs an argument" >&2; exit 2; }
            intake_file="$2"; shift 2 ;;
        --intake-file=*) intake_file="${1#--intake-file=}"; shift ;;
        --platforms)
            [ $# -ge 2 ] || { echo "onboard-project.sh: --platforms needs an argument" >&2; exit 2; }
            platforms_override="$2"; platforms_override_present=1; shift 2 ;;
        --platforms=*) platforms_override="${1#--platforms=}"; platforms_override_present=1; shift ;;
        --*)
            echo "onboard-project.sh: unknown flag: $1" >&2
            usage >&2; exit 2 ;;
        *)
            if [ -z "${source_path}" ]; then
                source_path="$1"; shift
            else
                echo "onboard-project.sh: unexpected positional argument: $1" >&2
                usage >&2; exit 2
            fi ;;
    esac
done

if [ -z "${source_path}" ]; then
    echo "onboard-project.sh: <source-path> is required." >&2
    usage >&2
    exit 2
fi

if [ ! -d "${source_path}" ]; then
    echo "onboard-project.sh: source-path is not a directory: ${source_path}" >&2
    exit 2
fi
source_path_abs="$(cd "${source_path}" && pwd)"

case "${type_hint}" in
    1|2|3|4|unknown) ;;
    *)
        echo "onboard-project.sh: --type must be 1, 2, 3, 4 (or omitted). Got: ${type_hint}" >&2
        exit 2 ;;
esac

intake_file_abs=""
if [ -n "${intake_file}" ]; then
    if [ ! -f "${intake_file}" ]; then
        echo "onboard-project.sh: --intake-file not found: ${intake_file}" >&2
        exit 2
    fi
    intake_dir_abs="$(cd "$(dirname "${intake_file}")" && pwd)"
    intake_file_abs="${intake_dir_abs}/$(basename "${intake_file}")"
fi

# ---------------------------------------------------------------------------
# Substrate-up check. We need both git-server (for the import push and the
# single-shot inspection) and the architect (for the post-onboarding attach
# step the operator will run next).
# ---------------------------------------------------------------------------
arch_container="${ARCHITECT_CONTAINER:-agent-architect}"
git_container="${GIT_SERVER_CONTAINER:-agent-git-server}"

is_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -q '^true$'
}

for c in "${git_container}" "${arch_container}"; do
    if ! is_running "${c}"; then
        cat >&2 <<EOF
onboard-project.sh: ${c} container is not running.

The substrate must be up before onboarding. Bring it up first:

    ./setup-linux.sh    # or ./setup-mac.sh
EOF
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Single-shot enforcement. The bare main.git on the git-server has exactly
# one commit (the initial empty commit from infra/git-server/init-repos.sh)
# when no onboarding has happened. Any further commit count means onboarding
# already ran (and committed both the source import and the handover, or
# something else has touched main). Fail fast before any state mutation.
# ---------------------------------------------------------------------------
commit_count=$(docker exec "${git_container}" \
    git --git-dir=/srv/git/main.git rev-list --count main 2>/dev/null \
    | tr -d '\r\n ' || true)

if [ -z "${commit_count}" ]; then
    cat >&2 <<EOF
onboard-project.sh: could not inspect main.git on ${git_container}.

This usually means the substrate is partially set up — main.git's initial
commit is missing. Re-run setup:

    ./setup-linux.sh    # or ./setup-mac.sh
EOF
    exit 1
fi

if [ "${commit_count}" -lt 1 ]; then
    cat >&2 <<EOF
onboard-project.sh: main.git has no commits (count=${commit_count}). Substrate
setup is incomplete; re-run ./setup-linux.sh (or setup-mac.sh).
EOF
    exit 1
fi

if [ "${commit_count}" -gt 1 ]; then
    cat >&2 <<EOF
onboard-project.sh: refusing to onboard.

main.git on ${git_container} contains ${commit_count} commits — onboarding
has already happened for this substrate (single-shot per project, see
spec §4 "Onboarder"). If you genuinely need to re-onboard, tear the
substrate down and recreate it from scratch. There is no in-place
re-onboarding pattern by design.
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Source-tree import. Run a one-shot helper container on agent-net, using
# the onboarder SSH key, to clone main, copy /source into it, commit, and
# push. The same identity then writes the handover from inside the
# onboarder container — both the import commit and the handover commit
# are authored as 'onboarder' for a clean audit trail.
#
# We do this from the host (rather than from the onboarder container's
# entrypoint) because it keeps the onboarder's container concerns to
# just running claude. If the import fails (empty source, network glitch,
# key permissions), the script aborts before bringing the onboarder up,
# which is the cheaper failure mode.
# ---------------------------------------------------------------------------
echo "Importing brownfield source tree from ${source_path_abs}..."

import_log="$(mktemp)"
trap 'rm -f "${import_log}"' EXIT

if ! docker run --rm \
        -v "${repo_root}/infra/keys/onboarder:/k:ro" \
        -v "${source_path_abs}:/src:ro" \
        --network agent-net \
        debian:bookworm-slim \
        sh -c '
            set -e
            apt-get update -qq >/dev/null 2>&1
            apt-get install -qq -y --no-install-recommends git openssh-client ca-certificates >/dev/null 2>&1
            cp /k/id_ed25519 /tmp/key
            chmod 600 /tmp/key
            export GIT_SSH_COMMAND="ssh -i /tmp/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
            tmp=$(mktemp -d)
            cd "$tmp"
            git clone -q git@git-server:/srv/git/main.git .
            if [ -z "$(ls -A /src 2>/dev/null)" ]; then
                echo "[onboard-import] FATAL: source directory at /src is empty." >&2
                exit 1
            fi
            # cp -a preserves source ownership (typically UID 1000 from the
            # host) while the temp clone is owned by root (this container).
            # Without normalisation, git refuses the working copy as
            # "dubious ownership". Chown back to root after copy.
            cp -a /src/. .
            chown -R root:root .
            git -c user.email=onboarder@substrate.local -c user.name=onboarder add -A
            if git -c user.email=onboarder@substrate.local -c user.name=onboarder diff --cached --quiet; then
                echo "[onboard-import] FATAL: nothing staged after copy — source contains only files git ignores?" >&2
                exit 1
            fi
            git -c user.email=onboarder@substrate.local -c user.name=onboarder commit -q -m "onboarding: import source materials"
            git -c user.email=onboarder@substrate.local -c user.name=onboarder push -q origin main
            echo "[onboard-import] pushed import commit."
        ' 2>"${import_log}"; then
    echo "onboard-project.sh: source import failed. Error log:" >&2
    sed 's/^/  /' "${import_log}" >&2
    exit 1
fi

echo "Source import complete."

# ---------------------------------------------------------------------------
# Platform inference (s014 B.6 / design call 1).
#
# Default path: walk canonical signal files at the source root and
# propose a platform set. The operator confirms or corrects during
# phase-1 elicitation. Override path: --platforms=<csv> supplied → skip
# inference and pass the operator's set through to the migration brief
# directly (design call 2).
# ---------------------------------------------------------------------------
if [ "${platforms_override_present}" -eq 1 ]; then
    inferred_csv="${platforms_override}"
    inferred_source="--platforms flag"
    echo "[onboard] platforms supplied via --platforms: ${inferred_csv:-(empty)}"
else
    inferred_csv=$("${repo_root}/infra/scripts/infer-platforms.sh" "${source_path_abs}")
    inferred_source="inference from /source signals"
    if [ -n "${inferred_csv}" ]; then
        echo "[onboard] inferred platforms from /source: ${inferred_csv}"
    else
        echo "[onboard] no platforms inferred from /source signals; the onboarder will elicit from the operator."
    fi
fi

# ---------------------------------------------------------------------------
# Bring up the onboarder under its own compose project so it doesn't
# collide with whatever else might be running. The default name is
# <repo-basename>-onboard; ONBOARD_COMPOSE_PROJECT overrides it for the
# end-to-end test.
# ---------------------------------------------------------------------------
project_base="$(basename "${repo_root}")"
project="${ONBOARD_COMPOSE_PROJECT:-${project_base}-onboard}"
export DISPATCH_COMPOSE_PROJECT="${DISPATCH_COMPOSE_PROJECT:-${project_base}-code-migration}"

cleanup() {
    echo
    echo "Tearing down onboarder (project=${project})..."
    docker compose -p "${project}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
    rm -f "${import_log}"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# s013 (F50): platform composition. The onboarder's platform set is
# always empty by design (per F50 design call 6 — the onboarder does
# not build, run, or test the source). compose-image.sh produces a
# hash-tagged image at the empty set; in practice this is a cache hit
# from the substrate's first onboarder commission. The mechanism is
# universal (every dispatched role goes through compose-image.sh);
# the onboarder's specific case is "empty platform set produces the
# static template build". No tool-surface validation: the onboarder
# has no section brief, and its embedded allowed-tools list (s012,
# F58) is invariant.
# ---------------------------------------------------------------------------
echo "[onboard] composing onboarder image..."
if ! onboarder_image=$("${repo_root}/infra/scripts/compose-image.sh" onboarder ""); then
    echo "[onboard] FATAL: onboarder image composition failed." >&2
    exit 1
fi
export ONBOARDER_IMAGE="${onboarder_image}"

# ---------------------------------------------------------------------------
# Phase 1 — onboarder elicits, writes migration brief and draft handover.
#
# The phase-1 prompt directs the operator-in-loop session to:
#   - confirm or correct the inferred platform set;
#   - author /work/briefs/onboarding/code-migration.brief.md per the
#     migration-brief template;
#   - author /work/briefs/onboarding/handover.draft.md per the
#     onboarder-handover-template, with section 3 (code structural
#     review) marked as a TODO placeholder for phase 3 to fill from
#     the migration report;
#   - commit both files with the message documented below; push;
#     discharge.
#
# The draft path is distinct from the canonical handover.md so the
# architect's first-attach detection (s012 A.6) does not fire
# prematurely. Phase 3 produces handover.md.
# ---------------------------------------------------------------------------
bootstrap_prompt_phase_1="Read /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md), /methodology/onboarder-handover-template.md, and /methodology/code-migration-brief-template.md.

The brownfield source materials are at /source (read-only); they have already been imported into /work as the initial commit. Your project type hint is: ${type_hint}. Operator-supplied initial context (if any) is at /onboarding-intake.md (a zero-length or absent file means none was provided).

Proposed platform set (from ${inferred_source}): \"${inferred_csv}\". Confirm or correct this with the operator during your elicitation pass; the confirmed set goes in the migration brief's Required platforms field.

THIS IS PHASE 1 OF THREE. Your tasks for this phase:

1. Synthesise the project from /source and the operator's intake.
2. Elicit operator priorities and unknowns interactively (the same elicitation loop as in the onboarder guide, batched 2-3 questions at a time).
3. Confirm or correct the proposed platform set with the operator.
4. Author /work/briefs/onboarding/code-migration.brief.md per /methodology/code-migration-brief-template.md. Required platforms must reflect the confirmed set. Required tool surface must match the platforms (e.g. python-extras → \"Bash(pip:*),Bash(ruff:*),Bash(mypy:*),Bash(python3:*)\" plus the survey staples for any other declared platform).
5. Author /work/briefs/onboarding/handover.draft.md per /methodology/onboarder-handover-template.md, with sections 1, 2, 4, 5, 6, 7, 8, 9 fully drafted. Section 3 (\"Code structural review\") must contain exactly this single placeholder line and nothing else:
       _TODO: code migration agent dispatching — phase 3 fills this in from the migration report._
6. Commit both files with the message 'onboarding: phase 1 — migration brief + draft handover'. Push to origin main. Discharge.

After you discharge, the host will dispatch the code migration agent (autonomous, no operator interaction). When the agent's migration report is committed, the host will re-invoke a fresh onboarder container for phase 3 — at which point your phase-1 work (this draft handover) and the migration report together produce the final handover.md."

echo "Commissioning onboarder PHASE 1 (project=${project})..."
echo

SOURCE_PATH="${source_path_abs}" \
INTAKE_FILE="${intake_file_abs:-/dev/null}" \
ONBOARDING_TYPE_HINT="${type_hint}" \
BOOTSTRAP_PROMPT="${bootstrap_prompt_phase_1}" \
    docker compose -p "${project}" --profile ephemeral run --rm \
        -e BOOTSTRAP_PROMPT \
        -e ONBOARDING_TYPE_HINT \
        onboarder

# Verify the migration brief and draft handover landed on main before
# proceeding to dispatch. The architect's /work clone is the
# verification surface (mirror check-brief.sh's pattern).
echo
echo "[onboard] verifying phase 1 outputs on origin/main..."
docker exec "${arch_container}" git -C /work fetch -q origin main 2>/dev/null || true
for required in "briefs/onboarding/code-migration.brief.md" "briefs/onboarding/handover.draft.md"; do
    if ! docker exec "${arch_container}" git -C /work cat-file -e "origin/main:${required}" 2>/dev/null; then
        cat >&2 <<EOF

onboard-project.sh: FATAL — phase 1 did not produce ${required} on origin/main.

The onboarder may have discharged early, or its push may not have
landed. Either re-run ./onboard-project.sh from scratch (tear down and
re-create the substrate first — single-shot enforcement will block
in-place retries) or inspect ${arch_container}'s /work to recover.
EOF
        exit 1
    fi
done
echo "[onboard] phase 1 outputs present: code-migration.brief.md, handover.draft.md."

# ---------------------------------------------------------------------------
# Phase 2 — host dispatches the code migration agent (autonomous).
#
# The dispatch helper composes the agent's image with the platforms
# declared in the migration brief, validates the brief's tool surface
# against the composed image, runs the agent container with /source
# mounted read-only, and blocks until the agent commits the migration
# report and discharges.
# ---------------------------------------------------------------------------
echo
echo "[onboard] PHASE 2: dispatching code migration agent..."
echo

docker exec agent-architect git -C /work fetch origin main && \
    docker exec agent-architect git -C /work pull --ff-only

SOURCE_PATH="${source_path_abs}" \
ARCHITECT_CONTAINER="${arch_container}" \
GIT_SERVER_CONTAINER="${git_container}" \
    "${repo_root}/infra/scripts/dispatch-code-migration.sh"

# ---------------------------------------------------------------------------
# Phase 3 — onboarder integrates findings, writes final handover.
#
# A fresh onboarder container reads the draft handover (phase 1) and
# the migration report (phase 2), integrates the report's findings into
# section 3, and commits the final handover at the canonical path
# briefs/onboarding/handover.md. The architect's first-attach detection
# keys on this file.
# ---------------------------------------------------------------------------
bootstrap_prompt_phase_3="Read /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md), /methodology/onboarder-handover-template.md, /methodology/code-migration-report-template.md, and the following project files (all in /work):

  - /work/briefs/onboarding/handover.draft.md (your phase-1 work)
  - /work/briefs/onboarding/code-migration.brief.md (the agent's commissioning brief)
  - /work/briefs/onboarding/code-migration.report.md (the agent's structural survey report; survey feedstock — not a gate)

THIS IS PHASE 3 OF THREE. Your tasks for this phase:

1. Integrate the migration report's findings into section 3 (\"Code structural review\") of the handover. Summarise the report's per-component intent, structural completeness, and findings such that an architect reading the handover gets the structural picture in one pass; reference the migration report by path for deeper reads. Severity-graded findings carry across (HIGH/LOW/INFO; framed for-architect's-attention, not gate-shaped).
2. If the migration report surfaces operational notes or open questions that warrant updates to other handover sections (e.g. a vendored upstream that the operator did not mention in phase 1 should be added to §9 carry-over hazards), integrate those too. Do not duplicate the report wholesale — the report is preserved on disk; reference it.
3. Produce /work/briefs/onboarding/handover.md as the FINAL handover (copy the draft, fill section 3, integrate any new context). Use the exact heading wording in /methodology/onboarder-handover-template.md — the architect's first-attach entrypoint scans for those headings.
4. Briefly review the final handover with the operator if they ask; the elicitation pass already happened in phase 1, so this should be a confirmation step, not another full pass.
5. Commit /work/briefs/onboarding/handover.md with the exact message 'onboarding: handover brief'. Push to origin main. Discharge.

The architect's first-attach detection keys on the canonical handover.md filename; once it lands on main, the next ./attach-architect.sh will seed the architect's first claude session against the handover."

echo
echo "Commissioning onboarder PHASE 3 (project=${project})..."
echo

SOURCE_PATH="${source_path_abs}" \
INTAKE_FILE="${intake_file_abs:-/dev/null}" \
ONBOARDING_TYPE_HINT="${type_hint}" \
BOOTSTRAP_PROMPT="${bootstrap_prompt_phase_3}" \
    docker compose -p "${project}" --profile ephemeral run --rm \
        -e BOOTSTRAP_PROMPT \
        -e ONBOARDING_TYPE_HINT \
        onboarder

# Verify the final handover landed on main.
echo
echo "[onboard] verifying phase 3 output on origin/main..."
docker exec "${arch_container}" git -C /work fetch -q origin main 2>/dev/null || true
if ! docker exec "${arch_container}" git -C /work cat-file -e "origin/main:briefs/onboarding/handover.md" 2>/dev/null; then
    cat >&2 <<EOF

onboard-project.sh: WARNING — phase 3 did not produce
briefs/onboarding/handover.md on origin/main.

The architect's first-attach detection will not fire without this file.
Inspect ${arch_container}'s /work to diagnose, or re-run phase 3
manually by re-invoking the onboarder against the existing draft and
migration report.
EOF
fi

# After all three phases complete, restart the architect so its
# entrypoint runs again with the just-pushed handover present in /work.
# The entrypoint pulls /work on every start (see infra/architect/
# entrypoint.sh, "s012 A.6: refresh /work on every entrypoint run"), so
# this restart is what makes the architect see briefs/onboarding/handover.md
# and trigger the first-attach bootstrap on the operator's next
# ./attach-architect.sh call. The architect is idle at this point in
# the brownfield flow (no claude session yet) so the restart is safe.
echo
echo "Restarting ${arch_container} so the next ./attach-architect.sh sees the handover..."
docker restart "${arch_container}" >/dev/null

# Wait briefly for the architect to come back; the entrypoint logs its
# banner when ready, but a slow start would leave the operator confused
# if they ran ./attach-architect.sh too quickly. A short busy-wait keeps
# this responsive without sleeping unconditionally.
for _ in $(seq 1 30); do
    if docker exec "${arch_container}" test -L /work/CLAUDE.md 2>/dev/null; then
        break
    fi
    sleep 1
done

# Print the next-step pointer.
cat <<'EOF'

================================================================================
  Onboarding complete.

  The onboarder has produced briefs/onboarding/handover.md on main.

  Next step — attach the architect with the handover as bootstrap context:

      ./attach-architect.sh

  The architect's entrypoint detects briefs/onboarding/handover.md on first
  attach (no SHARED-STATE.md present yet) and seeds the architect's first
  claude session against it. From there, review and ratify the candidate
  SHARED-STATE.md and TOP-LEVEL-PLAN.md drafts with the architect, and
  begin the project's methodology from this synthesis.
================================================================================
EOF
