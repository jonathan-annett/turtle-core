#!/bin/bash
# Generate per-role SSH keypairs under infra/keys/<role>/. Idempotent —
# existing keys are left in place. Roles that ever need to push or pull
# from the internal git-server need a key here.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keys_dir="${repo_root}/infra/keys"

roles=(architect planner coder auditor human)

for role in "${roles[@]}"; do
    rdir="${keys_dir}/${role}"
    mkdir -p "${rdir}"
    chmod 700 "${rdir}"
    keyfile="${rdir}/id_ed25519"
    if [ -f "${keyfile}" ]; then
        echo "Key for ${role} already exists at ${keyfile}; leaving in place."
        continue
    fi
    ssh-keygen -t ed25519 -N '' -C "${role}@substrate" -f "${keyfile}" >/dev/null
    chmod 600 "${keyfile}"
    chmod 644 "${keyfile}.pub"
    echo "Generated key for ${role}."
done
