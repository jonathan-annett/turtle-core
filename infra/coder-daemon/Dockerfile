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
# Project build toolchain — extend HERE for downstream projects.
# Examples:
#   RUN apt-get update && apt-get install -y --no-install-recommends rustc cargo
#   RUN apt-get update && apt-get install -y --no-install-recommends golang-go
#   RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
# The proof-of-concept (timestamps CLI) needs only node + tsc, which are
# covered by the base nodejs/npm above.
# ----------------------------------------------------------------------------

# Daemon working dir.
RUN mkdir -p /daemon /data && chown -R agent:agent /daemon /data

USER agent
WORKDIR /daemon

COPY --chown=agent:agent package.json /daemon/package.json
RUN npm install --omit=dev --no-fund --no-audit

COPY --chown=agent:agent --chmod=0755 daemon.js              /daemon/daemon.js
COPY --chown=agent:agent              parse-tool-surface.js /daemon/parse-tool-surface.js
COPY --chown=agent:agent --chmod=0755 entrypoint.sh           /daemon/entrypoint.sh

ENTRYPOINT ["/daemon/entrypoint.sh"]
