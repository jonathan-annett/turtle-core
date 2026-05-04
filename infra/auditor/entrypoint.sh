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
