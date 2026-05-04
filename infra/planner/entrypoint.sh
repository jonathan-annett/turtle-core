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
if [ -n "${BOOTSTRAP_PROMPT:-}" ]; then
    echo
    echo "Bootstrap prompt detected; invoking claude non-interactively."
    echo "When claude discharges, you'll be dropped into a shell."
    echo
    claude -p "${BOOTSTRAP_PROMPT}" || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
