# Hand-rolled git-over-ssh server.
# Chosen over gitea: this is an internal localhost-only origin used only by
# agent containers on the compose bridge network. No web UI, no HTTP, no
# user/org/issue management. Per-role SSH keys identify the role; an update
# hook applies the spec §3.3 access table.

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        git openssh-server ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /var/run/sshd

# Create the git user. UID 1100 to avoid colliding with the agent UID 1000
# used in the role images. The login shell is /bin/bash, NOT git-shell:
# our wrapper in /srv/git-shell-wrapper handles GIT_USER export and then
# exec's git-shell to enforce the git-only restriction. If git-shell were
# the login shell, sshd would run our 'command="..."' through it and
# git-shell would reject the wrapper as an unrecognized command.
# `passwd -d` removes the locked-by-default empty password marker;
# without it sshd refuses key-based logins for accounts considered locked.
# PasswordAuthentication is 'no' in sshd_config below.
RUN useradd -m -s /bin/bash -u 1100 git \
    && passwd -d git \
    && mkdir -p /home/git/.ssh \
    && chown -R git:git /home/git \
    && chmod 700 /home/git/.ssh

# Disable password auth, root login, and other non-key paths.
RUN sed -i \
        -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
        -e 's/^#*UsePAM.*/UsePAM no/' \
        /etc/ssh/sshd_config \
    && echo 'AuthorizedKeysFile /home/git/.ssh/authorized_keys' >> /etc/ssh/sshd_config


# Bare-repo storage. Backed by named volumes in compose.
RUN mkdir -p /srv/git && chown git:git /srv/git

COPY --chmod=0755 git-shell-wrapper /srv/git-shell-wrapper
COPY --chmod=0755 init-repos.sh    /srv/init-repos.sh
COPY --chmod=0755 entrypoint.sh    /srv/entrypoint.sh
COPY --chmod=0755 hooks/update     /srv/hooks/update

EXPOSE 22

ENTRYPOINT ["/srv/entrypoint.sh"]
