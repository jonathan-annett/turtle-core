#!/bin/bash
# Architect container entrypoint.
#  - Clone main.git into /work if empty (read+write, restricted by the
#    git-server update hook to coordination paths).
#  - Clone auditor.git into /auditor if empty (architect has read-only
#    access; pushes will be rejected by the hook, that's the design).
#  - Drop into an interactive bash shell so 'docker compose attach
#    architect' gives the human a usable terminal where they can run
#    'claude' or 'claude --resume'.

set -euo pipefail

# Permissions on the mounted ssh key may be too loose for ssh to accept
# (named-volume default is 0755). Tighten in-place; the mount is read-only
# so we copy to a writable location first.
if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# claude-code stores its config + project state in ~/.claude.json (a sibling
# to ~/.claude/, not inside it). The volume mounts at /home/agent/.claude/,
# so without intervention .claude.json lands in the writable container layer
# and is lost across container recreation. Migrate any existing regular file
# into the volume, then symlink. Idempotent.
if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
fi
ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json

cd /

if [ ! -d /work/.git ]; then
    echo "Cloning main.git into /work..."
    git clone git@git-server:/srv/git/main.git /work
fi

if [ ! -d /auditor/.git ]; then
    echo "Cloning auditor.git into /auditor (read-only working copy)..."
    git clone git@git-server:/srv/git/auditor.git /auditor || {
        echo "Note: auditor.git clone failed — the repo may have no commits yet."
        echo "      Re-run 'git clone git@git-server:/srv/git/auditor.git /auditor' once the auditor repo has been seeded."
    }
fi

# Set sane git identity for architect commits.
git -C /work config user.name  "architect"
git -C /work config user.email "architect@substrate.local"
[ -d /auditor/.git ] && git -C /auditor config user.name  "architect"
[ -d /auditor/.git ] && git -C /auditor config user.email "architect@substrate.local"

cat <<'EOF'

================================================================================
  Architect container
================================================================================

  Working clone of main:   /work
  Read-only auditor clone: /auditor
  Methodology docs:        /methodology

  Run 'claude --resume' to resume your persistent session, or 'claude' to
  start a new one. Your session state persists across container restarts
  via the claude-state-architect docker volume.

  Per the methodology spec §3.3, this container can push only to:
      briefs/**, SHARED-STATE.md, TOP-LEVEL-PLAN.md, README.md, MIGRATION-*.md
  on refs/heads/main. Other paths and refs are rejected by the git-server.

  Detach without stopping:  Ctrl-P then Ctrl-Q  (default docker keys)
  Stop the container:       'exit' or 'docker compose stop architect'

================================================================================

EOF

cd /work
exec bash -l
