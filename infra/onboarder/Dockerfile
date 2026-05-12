# Onboarder: ephemeral, project-scoped, single-shot claude-code session.
# The onboarder reads /source (the brownfield project tree, mounted
# read-only), synthesises a handover brief with operator-in-loop
# elicitation, and pushes it to briefs/onboarding/handover.md in main.
#
# No target-language toolchains here — the onboarder does not build,
# run, or test the source. Structural code review and history
# reconstruction belong to the (future) code-migration and history-
# migration sub-agents (Sections B and C); F50 platform composition
# applies to those, not to this shell.

FROM agent-base

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
