# Planner: ephemeral claude-code session, one per section. Minimal — the
# planner commissions coders via HTTP to coder-daemon, doesn't build code.

FROM agent-base

# ----------------------------------------------------------------------------
# Project planner toolchain. The line below is the sentinel consumed by
# infra/scripts/render-dockerfile.sh — the renderer composes the
# selected platform plugin layers (methodology/platforms/<name>.yaml)
# in place of this comment when producing the rendered Dockerfile.
# With no platform layers (the typical case for the planner — it
# orchestrates rather than builds), the sentinel is simply removed and
# the resulting image is byte-equivalent to this template's static
# build aside from a generated-file header. s013 (F50) made the
# planner a participant in JIT composition so a section with
# Required platforms: <list> can compose a planner image carrying
# those platforms without special-casing the role.
# ----------------------------------------------------------------------------
# PLATFORM_INSERT_HERE

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

# s011 11.e: the entrypoint parses the section brief's "Required tool
# surface" field (spec §7.2) before invoking claude non-interactively
# and passes the result as --allowed-tools. The parser is bind-mounted
# at runtime from the host (see docker-compose.yml) at
# /usr/local/lib/turtle-core/parse-tool-surface.sh so the bash port and
# the coder-daemon's JS port stay single-source-of-truth in the repo.

ENTRYPOINT ["/home/agent/entrypoint.sh"]
