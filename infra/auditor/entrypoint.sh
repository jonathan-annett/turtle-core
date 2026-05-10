#!/bin/bash
# Auditor container entrypoint.
#  - Clone main.git into /work as a read-only working copy. Read access is
#    granted by the SSH key; write attempts are rejected by the update hook
#    (spec §3.3 — auditor has no main-repo write).
#  - Clone auditor.git into /auditor as the writable workspace.
#  - Drop into a bash shell so the human can run 'claude' against the audit
#    brief.

set -euo pipefail

if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# .claude.json lives inside the claude-state-shared volume. Symlink the
# container-layer path to it (migrating first if a regular file exists).
if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
fi
ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json

cd /

if [ ! -d /work/.git ]; then
    echo "Cloning main.git into /work (read-only working copy)..."
    git clone git@git-server:/srv/git/main.git /work
fi

if [ ! -d /auditor/.git ]; then
    echo "Cloning auditor.git into /auditor (writable workspace)..."
    git clone git@git-server:/srv/git/auditor.git /auditor || {
        echo "Note: auditor.git appears empty. Initializing local repo;"
        echo "      you can 'git push origin main' once you have a first commit."
        mkdir -p /auditor && cd /auditor && git init -q -b main && \
            git remote add origin git@git-server:/srv/git/auditor.git
        cd /
    }
fi

git -C /work    config user.name  "auditor"
git -C /work    config user.email "auditor@substrate.local"
git -C /auditor config user.name  "auditor"
git -C /auditor config user.email "auditor@substrate.local"

# Role anchor: symlink CLAUDE.md to the auditor methodology guide so
# the auditor's claude-code session loads it automatically. The
# auditor reads its audit brief from /work (read-only main clone) and
# writes the audit report into /auditor; the role anchor lives at
# /work/CLAUDE.md, where claude-code looks first. Idempotent; repo-
# local via .git/info/exclude (the git-server hook would reject any
# auditor push to main anyway).
ln -sfn /methodology/auditor-guide.md /work/CLAUDE.md
if ! grep -qxF 'CLAUDE.md' /work/.git/info/exclude 2>/dev/null; then
    printf 'CLAUDE.md\n' >> /work/.git/info/exclude
fi

cat <<'EOF'

================================================================================
  Auditor container (ephemeral)
================================================================================

  Read-only working copy of main:  /work
  Writable auditor workspace:      /auditor
  Methodology docs:                /methodology

  You have NO write access to the main repo. The git-server enforces this.
  Audit reports go in the auditor repo. The architect ferries the report
  into the main repo after you discharge.

  Run 'claude' and supply your audit brief filepath.

================================================================================

EOF

cd /work

# s008 8.e: BOOTSTRAP_PROMPT — when audit.sh is invoked with a section
# slug it sets this env var. Run claude non-interactively against the
# prompt before dropping to a shell. The trailing '|| true' keeps the
# shell reachable for post-discharge inspection even if claude exits
# non-zero.
#
# s011 11.f: when bootstrap-mode is active, also parse the audit brief's
# "Required tool surface" field (spec §7.6) via the shared parser at
# /usr/local/lib/turtle-core/parse-tool-surface.sh (bash port of
# infra/coder-daemon/parse-tool-surface.js). Pass the result as
# --allowed-tools to claude. Same shape and failure semantics as the
# planner side; the auditor reads its brief from /work (read-only main
# clone) and writes only to /auditor.
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
        brief_path=$(printf '%s' "${BOOTSTRAP_PROMPT}" | sed -n 's|.*Read /work/\([^ ][^ ]*\).*|/work/\1|p' | head -n1)
    fi

    if [ -z "${brief_path}" ] || [ ! -f "${brief_path}" ]; then
        cat >&2 <<EOF
FATAL: auditor bootstrap was given no usable BRIEF_PATH.

BRIEF_PATH=${BRIEF_PATH:-<unset>}
Heuristic-extracted: ${brief_path:-<empty>}

The auditor entrypoint needs the audit brief's filesystem path
inside the container to parse the 'Required tool surface' field.
audit.sh should set BRIEF_PATH=/work/briefs/<slug>/audit.brief.md.
EOF
        exec bash -l
    fi

    echo "Parsing tool surface from ${brief_path}..."
    if ! allowed_tools=$("${parser}" "${brief_path}"); then
        cat >&2 <<EOF

FATAL: auditor cannot start — audit brief is missing a usable
'Required tool surface' field. See the error above; the architect
must author the field per methodology/agent-orchestration-spec.md
§7.6. Until that is fixed, every verification command the auditor
needs would be silently denied by claude.

Dropping to shell so you can inspect ${brief_path} and post-mortem.
EOF
        exec bash -l
    fi
    echo "Allowed tools: ${allowed_tools}"
    echo

    # --permission-mode dontAsk + --allowed-tools mirrors the coder-daemon's
    # invocation pattern (deployment-doc §4.5 #Coder): out-of-allowlist
    # actions deny rather than prompt. Non-interactive bootstrap has no
    # human in the loop to unblock a permission dialogue.
    claude -p "${BOOTSTRAP_PROMPT}" \
        --permission-mode dontAsk \
        --allowed-tools "${allowed_tools}" \
        || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
