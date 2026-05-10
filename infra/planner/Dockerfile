# Planner: ephemeral claude-code session, one per section. Minimal — the
# planner commissions coders via HTTP to coder-daemon, doesn't build code.

FROM agent-base

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

# s011 11.e: the entrypoint parses the section brief's "Required tool
# surface" field (spec §7.2) before invoking claude non-interactively
# and passes the result as --allowed-tools. The parser is bind-mounted
# at runtime from the host (see docker-compose.yml) at
# /usr/local/lib/turtle-core/parse-tool-surface.sh so the bash port and
# the coder-daemon's JS port stay single-source-of-truth in the repo.

ENTRYPOINT ["/home/agent/entrypoint.sh"]
