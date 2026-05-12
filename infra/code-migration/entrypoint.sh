#!/bin/bash
# Code migration agent container entrypoint.
#  - Clone main.git into /work (ephemeral; a fresh clone per dispatch is
#    correct — the agent runs once per onboarding, and the migration
#    brief is already pushed by the onboarder before dispatch).
#  - Mount /source (read-only) carries the brownfield source materials
#    (same mount the onboarder reads from).
#  - Honour BOOTSTRAP_PROMPT (s008 pattern): when set, drive claude
#    non-interactively (-p mode, design call 5 of section B) with the
#    migration brief's tool surface parsed into --allowed-tools.
#  - Drop into bash on discharge for post-mortem inspection if the agent
#    exits non-zero.

set -euo pipefail

if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# .claude.json lives inside the claude-state-shared volume (carried in
# via verify.sh / setup-common.sh's architect→shared sync). Symlink the
# container-layer path to it. Migrate first if a regular file is present.
if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
fi
ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json

cd /

if [ ! -d /work/.git ]; then
    echo "Cloning main.git into /work..."
    git clone git@git-server:/srv/git/main.git /work
fi

git -C /work config user.name  "code-migration"
git -C /work config user.email "code-migration@substrate.local"

# Role anchor: symlink CLAUDE.md to the code-migration agent guide so
# the agent's claude-code session loads it automatically. Same pattern
# as the other role containers; kept repo-local via .git/info/exclude
# (the git-server hook would reject any non-report path anyway).
ln -sfn /methodology/code-migration-agent-guide.md /work/CLAUDE.md
if ! grep -qxF 'CLAUDE.md' /work/.git/info/exclude 2>/dev/null; then
    printf 'CLAUDE.md\n' >> /work/.git/info/exclude
fi

cat <<'EOF'

================================================================================
  Code migration agent container (ephemeral, single-shot per onboarding)
================================================================================

  Working clone of main:    /work
  Source materials:         /source  (read-only)
  Methodology docs:         /methodology

  Migration brief:          /work/briefs/onboarding/code-migration.brief.md
  This container exists to produce one artifact:
      /work/briefs/onboarding/code-migration.report.md

  Per spec §3.3, this container can push to refs/heads/main for the
  exact path briefs/onboarding/code-migration.report.md only. Other
  paths and refs are rejected by the git-server's update hook.

================================================================================

EOF

cd /work

# s008 8.d / B.3: BOOTSTRAP_PROMPT — when the dispatch helper invokes
# the container with a migration brief, it sets this env var plus
# BRIEF_PATH (the migration brief's path inside the container). Parse
# the brief's "Required tool surface" field via the shared parser at
# /usr/local/lib/turtle-core/parse-tool-surface.sh (bash port of
# infra/coder-daemon/parse-tool-surface.js, bind-mounted from the host).
# Pass the result as --allowed-tools to claude. Non-interactive (-p)
# mode is design call 5 of section B — the agent surveys, the
# onboarder synthesises, the operator is not in the loop for this step.
# Trailing '|| true' keeps the shell reachable for post-mortem
# inspection if claude exits non-zero.
if [ -n "${BOOTSTRAP_PROMPT:-}" ]; then
    echo
    echo "Bootstrap prompt detected; invoking claude non-interactively."
    echo "When claude discharges, you'll be dropped into a shell."
    echo

    parser=/usr/local/lib/turtle-core/parse-tool-surface.sh
    if [ ! -x "${parser}" ]; then
        cat >&2 <<EOF
FATAL: tool-surface parser not found at ${parser}.

Expected the parser to be bind-mounted from the host at:
    ./infra/scripts/lib/parse-tool-surface.sh

If you have just pulled an update that introduces this file, re-run
verify.sh on the host (or restart the substrate) so the volume mount
takes effect.
EOF
        exec bash -l
    fi

    brief_path="${BRIEF_PATH:-}"
    if [ -z "${brief_path}" ]; then
        # Defensive: extract the brief path from the prompt itself.
        # The canonical dispatch prompt encodes it as "Read /work/<path>".
        brief_path=$(printf '%s' "${BOOTSTRAP_PROMPT}" | sed -n 's|.*Read /work/\([^ ][^ ]*\).*|/work/\1|p' | head -n1)
    fi

    if [ -z "${brief_path}" ] || [ ! -f "${brief_path}" ]; then
        cat >&2 <<EOF
FATAL: code-migration bootstrap was given no usable BRIEF_PATH.

BRIEF_PATH=${BRIEF_PATH:-<unset>}
Heuristic-extracted: ${brief_path:-<empty>}

The code-migration entrypoint needs the migration brief's filesystem
path inside the container to parse the 'Required tool surface' field.
dispatch-code-migration.sh should set
BRIEF_PATH=/work/briefs/onboarding/code-migration.brief.md.
EOF
        exec bash -l
    fi

    echo "Parsing tool surface from ${brief_path}..."
    if ! allowed_tools=$("${parser}" "${brief_path}"); then
        cat >&2 <<EOF

FATAL: code-migration cannot start — migration brief is missing a
usable 'Required tool surface' field. See the error above; the
onboarder must author the field per
methodology/code-migration-brief-template.md. Until that is fixed,
every survey probe would be silently denied by claude.

Dropping to shell so you can inspect ${brief_path} and post-mortem.
EOF
        exec bash -l
    fi
    echo "Allowed tools: ${allowed_tools}"
    echo

    # --permission-mode dontAsk + --allowed-tools: out-of-allowlist
    # actions deny rather than prompt. Non-interactive bootstrap has no
    # human in the loop to unblock a permission dialogue. -p mode keeps
    # this consistent with planner and auditor.
    claude -p "${BOOTSTRAP_PROMPT}" \
        --permission-mode dontAsk \
        --allowed-tools "${allowed_tools}" \
        || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
