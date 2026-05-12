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
else
    # s012 A.6: refresh /work on every entrypoint run. The architect's
    # /work is a persistent named volume; without this pull, a handover
    # brief pushed to main while the architect was running (the brownfield
    # onboarding flow — onboarder runs while architect is idle, then
    # operator restarts architect to attach) would not be visible in
    # /work and the handover-detection block below would never fire.
    # --ff-only because the architect must not silently absorb diverged
    # history; if a real conflict appears it should surface here.
    git -C /work pull --ff-only --quiet || \
        echo "warning: 'git pull --ff-only' in /work failed; the architect's clone may be ahead of, or diverged from, origin/main."
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

# Role anchor: claude-code reads CLAUDE.md from the working tree on
# session start and treats it as the agent's prompt header. Symlinking
# the role guide makes the architect load its methodology guide
# automatically, no human seed prompt needed. Idempotent; the symlink
# stays repo-local via .git/info/exclude (the architect's git-server
# update hook would reject CLAUDE.md anyway, but excluding it keeps
# 'git status' clean).
ln -sfn /methodology/architect-guide.md /work/CLAUDE.md
if ! grep -qxF 'CLAUDE.md' /work/.git/info/exclude 2>/dev/null; then
    printf 'CLAUDE.md\n' >> /work/.git/info/exclude
fi

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

# s012 A.6: first-attach handover detection. For brownfield projects that
# went through ./onboard-project.sh, the onboarder produced a handover at
# /work/briefs/onboarding/handover.md. On the architect's first attach
# (no SHARED-STATE.md present yet — the architect hasn't done any work),
# bootstrap the architect's first claude session against the handover so
# the operator does not have to seed it manually.
#
# After the first attach, SHARED-STATE.md exists (the architect adopts it
# from the handover candidate), and the trigger condition fails on every
# subsequent attach — the architect resumes its persistent session via
# `claude --resume` interactively as before. The handover file itself is
# preserved on disk as a historical artifact; we only key off its
# presence-without-SHARED-STATE for the bootstrap trigger.
#
# Greenfield projects (no /work/briefs/onboarding/handover.md) reach the
# plain interactive shell with no behaviour change — exactly the same as
# the architect entrypoint behaved before s012.
handover_path="/work/briefs/onboarding/handover.md"
shared_state_path="/work/SHARED-STATE.md"

if [ -f "${handover_path}" ] && [ ! -f "${shared_state_path}" ]; then
    bootstrap_prompt="Read ${handover_path}, which is the onboarding handover brief for this project (produced by the onboarder before you attached). It contains nine sections: project identity, source materials inventory, code structural review, history review, a SHARED-STATE.md candidate, a TOP-LEVEL-PLAN.md candidate, known unknowns, the operator's stated priorities, and carry-over hazards. Adopt the SHARED-STATE.md candidate and the TOP-LEVEL-PLAN.md candidate as your starting drafts at /work/SHARED-STATE.md and /work/TOP-LEVEL-PLAN.md. Refine them with the operator, who is attached to this session interactively. Use sections 7 (known unknowns) and 8 (operator's stated priorities) as your first agenda. When you and the operator are satisfied with SHARED-STATE.md and TOP-LEVEL-PLAN.md, commit and push them to main, then begin the project's methodology from this point."

    echo
    echo "Onboarding handover detected; bootstrapping architect's first session"
    echo "against ${handover_path}."
    echo
    echo "On exit (Ctrl-D or 'exit'), you'll be dropped to a shell. Detach the"
    echo "container without stopping it via Ctrl-P Ctrl-Q to keep the architect"
    echo "running for subsequent ./attach-architect.sh sessions."
    echo

    # Plain `claude "<prompt>"` (not `claude -p`): the operator is in the
    # loop, conversing with the architect interactively from the first
    # message onward. This mirrors the onboarder entrypoint's pattern and
    # differs deliberately from the planner/auditor entrypoints' --print
    # invocation (those roles run without a human in the loop).
    #
    # No --allowed-tools / --permission-mode here: the architect's
    # surface is broad by design and is governed by claude-code's
    # default interactive permissioning, which suits the persistent
    # architect-with-human conversational shape.
    claude "${bootstrap_prompt}" || true

    echo
    echo "Architect bootstrap session ended. Dropping to interactive shell."
    echo "Use 'claude --resume' to resume the session you just had, or"
    echo "'claude' to start a new one."
    echo
fi

exec bash -l
