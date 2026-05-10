#!/bin/bash
# commission-pair.sh [<section-slug>]
#
# Starts a coder-daemon and planner pair for a given section, with a per-pair
# random port and bearer token. Pair runs in its own compose project namespace
# so multiple pairs can coexist. On planner exit (any cause) the daemon is
# torn down via 'compose down -v' and the env file removed.
#
# Brief §4.3 + deployment-doc §3.4. Dual-mode per s008:
#
#   commission-pair.sh <section-slug>   (commissioning mode)
#     - Verifies the section brief exists on main (via the architect clone).
#     - Generates a deterministic bootstrap prompt and passes it to the
#       planner container as BOOTSTRAP_PROMPT. The planner entrypoint
#       invokes claude non-interactively with that prompt before dropping
#       to a shell, eliminating the human-paste step.
#     - Fails fast if the brief is missing.
#
#   commission-pair.sh   (no argument — shell-only mode)
#     - Skips the brief check; preserves the legacy "drop straight to a
#       shell so I can poke the container manually" path. Useful during
#       substrate iteration. The human can still run claude interactively
#       inside the planner.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# shellcheck source=infra/scripts/lib/check-brief.sh
source "${repo_root}/infra/scripts/lib/check-brief.sh"

if [ "$#" -gt 1 ]; then
    cat >&2 <<'EOF'
Usage: ./commission-pair.sh [<section-slug>]

With <section-slug>: verify the brief exists, then commission the planner
                     non-interactively with a deterministic bootstrap prompt.

Without argument:    drop straight to a shell in the planner container for
                     manual inspection / debugging.

Example:
    ./commission-pair.sh s001-hello-timestamps
EOF
    exit 1
fi

section="${1:-}"
project_base="$(basename "${repo_root}")"

if [ -n "${section}" ]; then
    project="${project_base}-${section}"
else
    project="${project_base}-shell-$$"
fi

# Argument-mode: verify brief exists before doing anything expensive.
brief_path=""
if [ -n "${section}" ]; then
    brief_path="briefs/${section}/section.brief.md"
    check_brief_exists "${brief_path}" || exit $?
fi

env_file="${repo_root}/.pairs/.pair-${section:-shell-$$}.env"
mkdir -p "${repo_root}/.pairs"
chmod 700 "${repo_root}/.pairs"

# ---------------------------------------------------------------------------
# Generate per-pair random port + token. Token is base64 → URL-safe form.
# ---------------------------------------------------------------------------
port=$(awk -v min=10000 -v max=65535 'BEGIN{srand();print int(min+rand()*(max-min+1))}')
token=$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-43)

umask 077
cat > "${env_file}" <<EOF
COMMISSION_HOST=coder-daemon
COMMISSION_PORT=${port}
COMMISSION_TOKEN=${token}
EOF

cleanup() {
    echo
    echo "Tearing down pair (project=${project})..."
    docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
    rm -f "${env_file}"
    echo "Pair tear-down complete."
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Bring up the daemon (background). It binds to its compose-network IP and
# waits for commissions from the planner.
# ---------------------------------------------------------------------------
echo "Starting coder-daemon for ${section:-manual-inspection} (project=${project})..."
docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral up -d coder-daemon

if [ -n "${section}" ]; then
    # Argument mode: build the deterministic bootstrap prompt and pass it
    # via env to the planner. The planner entrypoint (s008 8.d) detects
    # BOOTSTRAP_PROMPT and invokes claude non-interactively.
    #
    # s011 11.e: BRIEF_PATH is passed alongside BOOTSTRAP_PROMPT so the
    # entrypoint can read the brief's "Required tool surface" field and
    # translate it into --allowed-tools. The path is absolute inside the
    # container (the planner mounts main.git's working clone at /work).
    bootstrap_prompt="Read /work/${brief_path} and execute the section per the methodology in /methodology/planner-guide.md (which is symlinked as /work/CLAUDE.md). The coder daemon is at http://coder-daemon:${port}. Your bearer token is in \$COMMISSION_TOKEN. Discharge when the section is done."

    echo "Commissioning planner against ${brief_path}"
    echo "Starting planner (foreground)..."
    BOOTSTRAP_PROMPT="${bootstrap_prompt}" \
    BRIEF_PATH="/work/${brief_path}" \
        docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral run --rm \
            -e BOOTSTRAP_PROMPT \
            -e BRIEF_PATH \
            planner
else
    # Shell-only mode: legacy path. Print the summary block so the human
    # can paste a prompt manually if they want, and drop into the shell.
    cat <<EOF

================================================================================
  Planner shell (no section slug supplied — manual mode)
================================================================================

  Daemon URL:     http://coder-daemon:${port}
  Bearer token:   (in your environment as \$COMMISSION_TOKEN)

  Run 'claude' inside the planner. Suggested prompt skeleton:

      Read /work/briefs/<section>/section.brief.md. The coder daemon is at
      http://coder-daemon:${port}. Your bearer token is in
      \$COMMISSION_TOKEN. Discharge when the section is done.

================================================================================
EOF
    echo "Starting planner (foreground)..."
    docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral run --rm planner
fi
