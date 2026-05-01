# Auditor: ephemeral claude-code session, one per audit. Minimal in the
# template; downstream projects extend this image with adversarial tools
# (fuzzers, static analyzers, exploit harnesses) per their domain.

FROM agent-base

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
