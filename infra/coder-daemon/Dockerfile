# Coder daemon: ephemeral, paired with planner. Runs an HTTP server that
# accepts task-brief commissions from the planner and spawns claude-code
# subshells (one at a time) to fulfil them.
#
# This image also carries the project's BUILD TOOLCHAIN, because coders
# run as subshells inside this container and need to compile/test the
# project. The base layer is node (used both for the daemon and for the
# proof-of-concept timestamps CLI). Downstream projects extend this image
# with their language toolchain.

FROM agent-base

USER root

# Node runtime + npm. The daemon uses Express + better-sqlite3 + uuid.
RUN apt-get update && apt-get install -y --no-install-recommends \
        nodejs npm \
        build-essential python3 \
    && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# Project build toolchain. The line below is the sentinel consumed by
# infra/scripts/render-dockerfile.sh — the renderer composes the
# selected platform plugin layers (methodology/platforms/<name>.yaml)
# in place of this comment when producing Dockerfile.generated. With
# --platform=default (or no flag) the sentinel is simply removed and
# the file is byte-equivalent to this template aside from a generated-
# file header.
# ----------------------------------------------------------------------------
# PLATFORM_INSERT_HERE

# Daemon working dir. USER root is re-asserted explicitly so the file is
# robust regardless of what the renderer emitted above (a platform block
# always ends in USER agent, by contract — see render-dockerfile.sh).
USER root
RUN mkdir -p /daemon /data && chown -R agent:agent /daemon /data

USER agent
WORKDIR /daemon

COPY --chown=agent:agent package.json /daemon/package.json
RUN npm install --omit=dev --no-fund --no-audit

COPY --chown=agent:agent --chmod=0755 daemon.js              /daemon/daemon.js
COPY --chown=agent:agent              parse-tool-surface.js /daemon/parse-tool-surface.js
COPY --chown=agent:agent --chmod=0755 entrypoint.sh           /daemon/entrypoint.sh

ENTRYPOINT ["/daemon/entrypoint.sh"]
