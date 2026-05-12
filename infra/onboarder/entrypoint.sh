#!/bin/bash
# Onboarder container entrypoint.
#  - Clone main.git into /work (ephemeral; a fresh clone per run is
#    correct — the onboarder runs once per project, and main is small
#    at this point: it holds the just-imported source tree and nothing
#    else).
#  - Mount /source (read-only) carries the brownfield materials the
#    operator pointed at via ./onboard-project.sh.
#  - Honour BOOTSTRAP_PROMPT (s008 pattern): when set, drive claude
#    with the prompt as the initial message before dropping to a shell.
#  - Drop into bash on discharge so the operator can inspect via the
#    onboard-project.sh dual-mode tail.

set -euo pipefail

if [ -f /home/agent/.ssh/id_ed25519 ]; then
    mkdir -p /home/agent/.ssh-rw
    cp /home/agent/.ssh/id_ed25519     /home/agent/.ssh-rw/id_ed25519
    cp /home/agent/.ssh/id_ed25519.pub /home/agent/.ssh-rw/id_ed25519.pub 2>/dev/null || true
    chmod 700 /home/agent/.ssh-rw
    chmod 600 /home/agent/.ssh-rw/id_ed25519
    export GIT_SSH_COMMAND="ssh -i /home/agent/.ssh-rw/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
fi

# .claude.json migration + symlink (same pattern as planner/auditor).
# The shared claude-state volume holds the auth state propagated from
# the architect by setup-common.sh / verify.sh; we want .claude.json
# to live inside it so config + project state survive container
# recreation.
if [ -f /home/agent/.claude.json ] && [ ! -L /home/agent/.claude.json ]; then
    mv /home/agent/.claude.json /home/agent/.claude/.claude.json
fi
ln -sfn /home/agent/.claude/.claude.json /home/agent/.claude.json

cd /

if [ ! -d /work/.git ]; then
    echo "Cloning main.git into /work..."
    git clone git@git-server:/srv/git/main.git /work
fi

git -C /work config user.name  "onboarder"
git -C /work config user.email "onboarder@substrate.local"

# Make sure the briefs/onboarding/ directory exists in the working
# clone so the operator/claude session can write the handover without
# a missing-parent error. The directory may already exist (idempotent).
mkdir -p /work/briefs/onboarding

# Role anchor: symlink CLAUDE.md to the onboarder methodology guide so
# claude-code loads it automatically on session start. Same pattern as
# the other role containers; kept repo-local via .git/info/exclude.
ln -sfn /methodology/onboarder-guide.md /work/CLAUDE.md
if ! grep -qxF 'CLAUDE.md' /work/.git/info/exclude 2>/dev/null; then
    printf 'CLAUDE.md\n' >> /work/.git/info/exclude
fi

# Surface the project-type hint and intake file's presence/absence for
# the banner; the bootstrap prompt also carries the type hint, but a
# human reading the container start-up output benefits from seeing it.
type_hint="${ONBOARDING_TYPE_HINT:-unknown}"
if [ -f /onboarding-intake.md ] && [ -s /onboarding-intake.md ]; then
    intake_status="present (/onboarding-intake.md)"
else
    intake_status="none (operator did not pass --intake-file)"
fi

cat <<EOF

================================================================================
  Onboarder container (ephemeral, single-shot per project)
================================================================================

  Working clone of main:    /work
  Source materials:         /source  (read-only)
  Methodology docs:         /methodology
  Operator intake file:     ${intake_status}
  Project type hint:        ${type_hint}

  This container exists to produce one artifact:
      /work/briefs/onboarding/handover.md

  Per the methodology spec §3.3, this container can push to refs/heads/main
  for paths under briefs/onboarding/** only. Other paths and refs are
  rejected by the git-server's update hook.

  Run 'claude' (or wait for the bootstrap prompt to drive it for you)
  and follow /methodology/onboarder-guide.md (symlinked as /work/CLAUDE.md).

================================================================================

EOF

cd /work

# s008 pattern, adapted for the onboarder. When ./onboard-project.sh
# sets BOOTSTRAP_PROMPT, drive claude with it as the initial message.
# Unlike planner/auditor (non-interactive, --print mode), the onboarder
# is interactive — the operator converses with claude during elicitation.
# We run plain `claude "<prompt>"` so the prompt seeds an interactive
# session rather than a one-shot completion.
#
# --permission-mode dontAsk + --allowed-tools sets the floor: claude
# will silently deny anything outside the list rather than prompting
# the operator mid-conversation. The list below covers the onboarder's
# inherent needs (read /source + /methodology, write briefs/onboarding/,
# git ops against main, lightweight shell inspection). This is *not*
# parsed from a brief (the onboarder has no section brief) — it is
# embedded here because the onboarder's tool surface is invariant
# across project types and stable from one run to the next.
#
# Trailing '|| true' keeps the shell reachable for post-discharge
# inspection even if claude exits non-zero, matching the planner pattern.
if [ -n "${BOOTSTRAP_PROMPT:-}" ]; then
    echo
    echo "Bootstrap prompt detected; starting interactive claude session."
    echo "When claude discharges, you'll be dropped into a shell."
    echo

    allowed_tools='Read,Edit,Write,Bash(ls:*),Bash(cat:*),Bash(find:*),Bash(grep:*),Bash(head:*),Bash(tail:*),Bash(wc:*),Bash(file:*),Bash(stat:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(git status:*),Bash(git diff:*),Bash(git log:*),Bash(git rev-parse:*),Bash(mkdir:*)'

    claude "${BOOTSTRAP_PROMPT}" \
        --permission-mode dontAsk \
        --allowed-tools "${allowed_tools}" \
        || true
    echo
    echo "Claude discharged. Dropping to interactive shell."
    echo
fi

exec bash -l
