#!/bin/bash
# onboard-project.sh <source-path> [--type 1|2|3|4] [--intake-file <path>]
#
# Operator-facing entry point for the onboarder (s012). Mints the
# brownfield project's main.git on the substrate's git-server, imports
# the source tree as the initial commit, then runs the onboarder
# container so the operator and claude-code produce the handover brief
# interactively. Single-shot: refuses to run a second time for the same
# project (enforced by inspecting the bare main.git on the git-server).
#
# Sibling of ./commission-pair.sh and ./audit.sh; same dual-mode flavor
# applied to a different role.
#
# Args:
#   <source-path>           Directory containing the brownfield project.
#                           Mounted into the onboarder read-only at /source.
#                           Required.
#   --type 1|2|3|4          Optional project-type hint (see the four-type
#                           taxonomy in methodology/onboarder-guide.md §4).
#                           If omitted, the onboarder infers / elicits.
#   --intake-file <path>    Optional file with operator-supplied initial
#                           context (notes, priorities, links). Mounted
#                           into the onboarder at /onboarding-intake.md.
#
# Env overrides (test fixture surface; production callers leave unset):
#   ARCHITECT_CONTAINER     Default agent-architect.
#   GIT_SERVER_CONTAINER    Default agent-git-server.
#   ONBOARD_COMPOSE_PROJECT Default <repo-basename>-onboard.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# ---------------------------------------------------------------------------
# Argument parsing.
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: ./onboard-project.sh <source-path> [--type 1|2|3|4] [--intake-file <path>]

  <source-path>         Directory containing the brownfield project. Mounted
                        read-only into the onboarder at /source.

  --type 1|2|3|4        Optional project-type hint. The onboarder infers
                        from /source if you omit this; pass it when the
                        type is unambiguous and you want to skip that step.

  --intake-file <path>  Optional markdown file with your initial framing
                        (goals, priorities, hard constraints, things you
                        want the architect to know on day one). Mounted at
                        /onboarding-intake.md inside the onboarder.

  -h, --help            Show this help.

The project's main.git on the substrate's git-server must be empty (only
the initial empty commit from setup). The script refuses to run otherwise;
onboarding is single-shot per project.

Example:
    ./onboard-project.sh ~/code/legacy-thing --type 2 --intake-file ~/onboarding-notes.md
EOF
}

source_path=""
type_hint="unknown"
intake_file=""

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
# Build the canonical onboarder bootstrap prompt. This becomes the
# methodology's reference prompt for onboarder commissioning, parallel to
# the planner/auditor prompts canonicalised in s008's report.
# ---------------------------------------------------------------------------
bootstrap_prompt="Read /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md) and /methodology/onboarder-handover-template.md. The brownfield source materials are at /source (read-only); they have already been imported into /work as the initial commit. Your project type hint is: ${type_hint}. Operator-supplied initial context (if any) is at /onboarding-intake.md (a zero-length or absent file means none was provided). Synthesise the project, elicit priorities and unknowns from the operator interactively, and produce the handover brief at /work/briefs/onboarding/handover.md following the nine-section structure in the template. When the operator is satisfied with the handover, commit with the exact message 'onboarding: handover brief', push to origin main, and discharge."

# ---------------------------------------------------------------------------
# Bring up the onboarder under its own compose project so it doesn't
# collide with whatever else might be running. The default name is
# <repo-basename>-onboard; ONBOARD_COMPOSE_PROJECT overrides it for the
# end-to-end test.
# ---------------------------------------------------------------------------
project_base="$(basename "${repo_root}")"
project="${ONBOARD_COMPOSE_PROJECT:-${project_base}-onboard}"

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

echo "Commissioning onboarder (project=${project})..."
echo

SOURCE_PATH="${source_path_abs}" \
INTAKE_FILE="${intake_file_abs:-/dev/null}" \
ONBOARDING_TYPE_HINT="${type_hint}" \
BOOTSTRAP_PROMPT="${bootstrap_prompt}" \
    docker compose -p "${project}" --profile ephemeral run --rm \
        -e BOOTSTRAP_PROMPT \
        -e ONBOARDING_TYPE_HINT \
        onboarder

# After the onboarder discharges (claude exits, then bash -l exits when
# the operator hits Ctrl-D or types `exit`), restart the architect so its
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
