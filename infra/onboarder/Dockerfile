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

# ----------------------------------------------------------------------------
# Onboarder toolchain. The line below is the sentinel consumed by
# infra/scripts/render-dockerfile.sh. The onboarder's platform set is
# always empty by design (see s013 / F50 design call 6: the onboarder
# does not build, run, or test the source — that belongs to follow-on
# sub-agents), so the sentinel is always removed and the resulting
# image is the static template build. The sentinel exists so the JIT
# composition mechanism is universal: every dispatched role goes
# through render-dockerfile.sh, with an empty platform set as the
# onboarder's specific case rather than a special-case shortcut.
# ----------------------------------------------------------------------------
# PLATFORM_INSERT_HERE

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
