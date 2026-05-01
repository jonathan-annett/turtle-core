# Architect: long-lived persistent claude-code session paired with the human.
# Minimal — no build toolchain (the architect doesn't build, only writes
# briefs and coordination files). Working clone of main lives at /work;
# read-only clone of auditor.git lives at /auditor.

FROM agent-base

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
