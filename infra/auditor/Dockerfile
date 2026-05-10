# Auditor: ephemeral claude-code session, one per audit. Minimal in the
# template; downstream projects extend this image with adversarial tools
# (fuzzers, static analyzers, exploit harnesses) per their domain.

FROM agent-base

USER root
RUN mkdir -p /auditor && chown agent:agent /auditor

# ----------------------------------------------------------------------------
# Project adversarial / static-analysis toolchain. The line below is the
# sentinel consumed by infra/scripts/render-dockerfile.sh — the renderer
# composes the selected platform plugin layers (methodology/platforms/
# <name>.yaml) in place of this comment when producing
# Dockerfile.generated. With --platform=default (or no flag) the sentinel
# is simply removed and the file is byte-equivalent to this template
# aside from a generated-file header.
# ----------------------------------------------------------------------------
# PLATFORM_INSERT_HERE

USER agent

COPY --chown=agent:agent --chmod=0755 entrypoint.sh /home/agent/entrypoint.sh

ENTRYPOINT ["/home/agent/entrypoint.sh"]
