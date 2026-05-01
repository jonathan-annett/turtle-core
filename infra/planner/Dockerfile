# Planner: ephemeral claude-code session, one per section. Minimal — the
# planner commissions coders via HTTP to coder-daemon, doesn't build code.

FROM agent-base

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
