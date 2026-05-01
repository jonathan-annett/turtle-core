#!/bin/bash
# Generate per-role SSH keypairs under infra/keys/<role>/. Idempotent —
# existing keys are left in place. Roles that ever need to push or pull
# from the internal git-server need a key here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keys_dir="${repo_root}/infra/keys"

roles=(architect planner coder auditor human)

# If running under sudo, return the keys to the invoking user so the
# in-container 'agent' user (UID 1000, matching the typical host UID) can
# read them when bind-mounted.
chown_target=""
if [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != "0" ]; then
    chown_target="${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}"
fi

for role in "${roles[@]}"; do
    rdir="${keys_dir}/${role}"
    mkdir -p "${rdir}"
    chmod 700 "${rdir}"
    [ -n "${chown_target}" ] && chown "${chown_target}" "${rdir}"
    keyfile="${rdir}/id_ed25519"
    if [ -f "${keyfile}" ]; then
        echo "Key for ${role} already exists at ${keyfile}; leaving in place."
        continue
    fi
    ssh-keygen -t ed25519 -N '' -C "${role}@substrate" -f "${keyfile}" >/dev/null
    chmod 600 "${keyfile}"
    chmod 644 "${keyfile}.pub"
    if [ -n "${chown_target}" ]; then
        chown "${chown_target}" "${keyfile}" "${keyfile}.pub"
    fi
    echo "Generated key for ${role}."
done
