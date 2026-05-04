#!/bin/bash
# infra/scripts/lib/check-brief.sh
#
# Shared helper for verifying that a brief file exists on main before
# commissioning a planner or auditor. Implemented per s008 design call 3:
# the architect's /work clone is the verification surface (always running
# during commissions; durable across substrate restarts).
#
# Source this file from another script and call:
#
#     check_brief_exists "briefs/s003-feature/section.brief.md"
#
# Returns 0 on success, non-zero with a useful error on failure. The
# error distinguishes the two common stale-state causes (committed but
# not pushed; on main but architect clone is behind) so the human can
# recover with one command.

check_brief_exists() {
    local brief_path="$1"

    if ! docker inspect -f '{{.State.Running}}' agent-architect 2>/dev/null | grep -q '^true$'; then
        cat >&2 <<EOF
FATAL: agent-architect container is not running.

The brief-existence check uses the architect's /work clone as its
verification surface (deployment-docker.md §6.2). Bring the architect
up first:

    docker compose up -d architect
EOF
        return 2
    fi

    if ! docker exec agent-architect test -f "/work/${brief_path}"; then
        cat >&2 <<EOF
FATAL: brief not found at ${brief_path} (in agent-architect:/work).

If the architect has just committed the brief, ensure it has been pushed:
    docker exec agent-architect git -C /work push

Or run an architect fetch if the brief is on main but not in the
architect's clone:
    docker exec agent-architect git -C /work fetch && \\
        docker exec agent-architect git -C /work pull
EOF
        return 1
    fi

    return 0
}
