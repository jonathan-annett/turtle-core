#!/bin/bash
# Planner container entrypoint.
#  - Clone main.git into /work (the planner is ephemeral; a fresh clone
#    each commission is correct, not wasteful — repos are small).
#  - Drop into a bash shell so the human can run 'claude' against the
#    section brief.

set -euo pipefail

if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# .claude.json lives inside the claude-state-shared volume (carried in via
# verify.sh / setup-common.sh's architect→shared sync). Symlink the
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

git -C /work config user.name  "planner"
git -C /work config user.email "planner@substrate.local"

# Role anchor: symlink CLAUDE.md to the planner methodology guide so the
# planner's claude-code session loads it automatically. Idempotent;
# kept repo-local via .git/info/exclude.
ln -sfn /methodology/planner-guide.md /work/CLAUDE.md
if ! grep -qxF 'CLAUDE.md' /work/.git/info/exclude 2>/dev/null; then
    printf 'CLAUDE.md\n' >> /work/.git/info/exclude
fi

cat <<EOF

================================================================================
  Planner container (ephemeral)
================================================================================

  Working clone of main:    /work
  Methodology docs:         /methodology
  Coder daemon:             http://${COMMISSION_HOST:-coder-daemon}:${COMMISSION_PORT:-?}
  Bearer token in env:      \$COMMISSION_TOKEN

  Per the methodology spec §3.3, this container can push only to
  refs/heads/section/* and refs/heads/task/*; pushes to main are rejected.

  Run 'claude' and supply your section brief filepath. The brief will tell
  you the section/task branch coordinates and how to commission coders.

================================================================================

EOF

cd /work

# s008 8.d: BOOTSTRAP_PROMPT — when commission-pair.sh is invoked with a
# section slug it sets this env var. Run claude non-interactively against
# the prompt before dropping to a shell. The trailing '|| true' keeps the
# shell reachable for post-discharge inspection even if claude exits non-
# zero.
#
# s011 11.e: when bootstrap-mode is active, also parse the section brief's
# "Required tool surface" field (spec §7.2) via the shared parser at
# /usr/local/lib/turtle-core/parse-tool-surface.sh (bash port of
# infra/coder-daemon/parse-tool-surface.js). Pass the result as
# --allowed-tools to claude so methodology-required git operations are
# permitted at runtime rather than silently denied. A missing or
# unparseable field fails clean before claude starts — the parser's
# stderr names the offending brief and the spec section to consult.
# Falls back to BRIEF_PATH env (commission-pair.sh sets it); legacy
# bootstrap prompts without BRIEF_PATH parse the path out of the prompt
# string as a defensive fallback.
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
        # Older bootstrap prompts encode it as "Read /work/<path>".
        brief_path=$(printf '%s' "${BOOTSTRAP_PROMPT}" | sed -n 's|.*Read /work/\([^ ][^ ]*\).*|/work/\1|p' | head -n1)
    fi

    if [ -z "${brief_path}" ] || [ ! -f "${brief_path}" ]; then
        cat >&2 <<EOF
FATAL: planner bootstrap was given no usable BRIEF_PATH.

BRIEF_PATH=${BRIEF_PATH:-<unset>}
Heuristic-extracted: ${brief_path:-<empty>}

The planner entrypoint needs the section brief's filesystem path
inside the container to parse the 'Required tool surface' field.
commission-pair.sh should set BRIEF_PATH=/work/briefs/<slug>/section.brief.md.
EOF
        exec bash -l
    fi

    echo "Parsing tool surface from ${brief_path}..."
    if ! allowed_tools=$("${parser}" "${brief_path}"); then
        cat >&2 <<EOF

FATAL: planner cannot start — section brief is missing a usable
'Required tool surface' field. See the error above; the architect
must author the field per methodology/agent-orchestration-spec.md
§7.2. Until that is fixed, every methodology-required git operation
in the planner would be silently denied by claude.

Dropping to shell so you can inspect ${brief_path} and post-mortem.
EOF
        exec bash -l
    fi
    echo "Allowed tools: ${allowed_tools}"
    echo

    # --permission-mode dontAsk + --allowed-tools mirrors the coder-daemon's
    # invocation pattern (deployment-doc §4.5 #Coder): out-of-allowlist
    # actions deny rather than prompt. Non-interactive bootstrap has no
    # human in the loop to unblock a permission dialogue. The interactive
    # path (manual-mode commission-pair.sh, no BOOTSTRAP_PROMPT) is
    # untouched and keeps the spec-default permission mode.
    claude -p "${BOOTSTRAP_PROMPT}" \
        --permission-mode dontAsk \
        --allowed-tools "${allowed_tools}" \
        || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
