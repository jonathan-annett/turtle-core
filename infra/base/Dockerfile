# agent-base: shared parent image for architect, planner, coder-daemon, auditor.
# Carries claude-code, git, ssh client, and an unprivileged 'agent' user.
# No build toolchain here — only coder-daemon needs that, and adding it to
# the base would bloat every other image.

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-client curl ca-certificates gnupg vim less procps jq \
    && rm -rf /var/lib/apt/lists/*

# Install claude-code via Anthropic's signed APT repository (deployment-doc §5.1).
# Pinning to the 'stable' channel; switch the source list to 'latest' for rolling.
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://downloads.claude.ai/keys/claude-code.asc \
        -o /etc/apt/keyrings/claude-code.asc \
    && echo "deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main" \
        > /etc/apt/sources.list.d/claude-code.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends claude-code \
    && rm -rf /var/lib/apt/lists/*

# Unprivileged user; UID 1000 to match the typical host UID and avoid
# named-volume permission surprises.
RUN useradd -m -s /bin/bash -u 1000 agent \
    && mkdir -p /work \
    && chown agent:agent /work

# System-wide ssh client config: every container in the substrate talks to
# the git-server service over the compose bridge network. The bridge is
# isolated and only reachable inside the project; relaxing host-key checks
# here keeps the agent containers from blocking on a known_hosts prompt.
RUN printf '%s\n' \
        'Host git-server' \
        '    User git' \
        '    StrictHostKeyChecking no' \
        '    UserKnownHostsFile /dev/null' \
        '    LogLevel ERROR' \
    >> /etc/ssh/ssh_config

USER agent
WORKDIR /work
