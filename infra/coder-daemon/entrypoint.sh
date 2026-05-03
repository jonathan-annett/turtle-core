#!/bin/bash
# Coder-daemon container entrypoint.
#  - Tighten ssh key permissions (named-volume default 0755 is too loose).
#  - Configure git identity for coder pushes.
#  - Exec the node daemon.

set -euo pipefail

if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# Coder subshells run as children of this daemon, sharing its filesystem.
# .claude.json lives inside the claude-state-shared volume; symlink so
# claude-code in the subshell finds it at the canonical path.
if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
fi
ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json

git config --global user.name  "coder"
git config --global user.email "coder@substrate.local"

cd /daemon
exec node daemon.js
