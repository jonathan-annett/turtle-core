# Code migration agent: ephemeral, project-onboarding-scoped, single-shot
# claude-code session. Dispatched by the onboarder during brownfield
# onboarding. Performs structural review of /source (the brownfield
# project tree, mounted read-only) and produces a survey report at
# briefs/onboarding/code-migration.report.md in main.
#
# Unlike the onboarder (whose platform set is always empty by design —
# see s013 / F50 design call 6), this role's image is composed with the
# target-language toolchains declared in the migration brief's "Required
# platforms" field. The onboarder authors that brief after inferring
# platforms from /source signals and (optionally) confirming with the
# operator. compose-image.sh produces a hash-tagged image with the
# resolved platform set at dispatch time.

FROM agent-base

# ----------------------------------------------------------------------------
# Code migration agent toolchain. The line below is the sentinel
# consumed by infra/scripts/render-dockerfile.sh. The platform set is
# determined per-onboarding by the migration brief's "Required
# platforms" field; the dispatch helper composes a hash-tagged image at
# dispatch time. Empty platform set produces the static template build
# aside from a generated-file header (same shape as onboarder's
# universal-mechanism participation; s013).
# ----------------------------------------------------------------------------
# PLATFORM_INSERT_HERE

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

# The entrypoint parses the migration brief's "Required tool surface"
# field (per methodology/code-migration-brief-template.md) before
# invoking claude non-interactively (-p mode, design call 5) and passes
# the result as --allowed-tools. The parser is bind-mounted at runtime
# from the host at /usr/local/lib/turtle-core/parse-tool-surface.sh so
# the bash port stays single-source-of-truth with the planner/auditor
# entrypoints in the repo.

ENTRYPOINT ["/home/agent/entrypoint.sh"]
