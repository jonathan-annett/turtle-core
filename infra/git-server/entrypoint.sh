#!/bin/bash
# Container entrypoint:
#   1. Generate ssh host keys if missing (image is built without them so they
#      are unique per deployment).
#   2. Build authorized_keys from the public keys mounted at /srv/keys/<role>/.
#      Each entry is constrained to a wrapper that exports GIT_USER=<role>.
#   3. Initialize the bare repos and install the update hook.
#   4. Exec sshd in the foreground.
set -euo pipefail

ssh-keygen -A -q

mkdir -p /home/git/.ssh
authorized="/home/git/.ssh/authorized_keys"
: > "${authorized}"
chmod 600 "${authorized}"

ssh_options="no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding"

found_any=0
for role in architect planner coder auditor human; do
    pubfile="/srv/keys/${role}/id_ed25519.pub"
    if [ -f "${pubfile}" ]; then
        keyline=$(tr -d '\n' < "${pubfile}")
        printf 'command="/srv/git-shell-wrapper %s",%s %s\n' \
            "${role}" "${ssh_options}" "${keyline}" >> "${authorized}"
        found_any=1
        echo "Authorized key loaded for role: ${role}"
    fi
done

chown -R git:git /home/git/.ssh

if [ "${found_any}" -eq 0 ]; then
    echo "WARNING: no role public keys found under /srv/keys; the server" >&2
    echo "         will reject every connection until keys are mounted."  >&2
fi

/srv/init-repos.sh

exec /usr/sbin/sshd -D -e
