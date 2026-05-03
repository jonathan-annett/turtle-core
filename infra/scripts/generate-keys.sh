#!/bin/bash
# Generate per-role SSH keypairs under infra/keys/<role>/. Idempotent —
# existing keys are left in place. Roles that ever need to push or pull
# from the internal git-server need a key here.
#
# This script is no longer standalone-safe in the way it once was. Per
# methodology/deployment-docker.md §3.5, regenerating keys behind a live
# substrate's back can desync the host's bind-mounted keys from what the
# running containers see. The precondition below blocks that case.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keys_dir="${repo_root}/infra/keys"

# ---------------------------------------------------------------------------
# Precondition: refuse to run unless one of the following is true.
#   (1) TURTLE_CORE_SETUP_AUTHORIZED=1 is set by setup-{linux,mac}.sh.
#       This covers both fresh-install (sentinel just written, volume
#       not yet created) and ordinary re-setup paths — setup has already
#       run the substrate_id_gate and confirmed state is consistent.
#   (2) Standalone invocation with a coherent substrate identity:
#       .substrate-id exists AND the claude-state-architect volume has a
#       matching app.turtle-core.substrate-id label.
# Without one of those, exit non-zero with a pointer at setup, which
# performs the proper diagnosis.
# ---------------------------------------------------------------------------
# shellcheck source=substrate-identity.sh
. "${repo_root}/infra/scripts/substrate-identity.sh"

if [ "${TURTLE_CORE_SETUP_AUTHORIZED:-0}" != "1" ]; then
    disk_id=$(substrate_id_read_disk) || {
        echo "generate-keys.sh: ${SUBSTRATE_ID_FILE} is malformed (see message above)." >&2
        exit 1
    }
    if [ -z "${disk_id}" ]; then
        cat >&2 <<EOF
generate-keys.sh: refusing to run.
  No ${SUBSTRATE_ID_FILE}, and TURTLE_CORE_SETUP_AUTHORIZED is not set.
  This script is no longer safe to run standalone — running it without
  setup's mediation can desync the host's keys from a live substrate.

  Run setup-linux.sh or setup-mac.sh; it will diagnose substrate state
  and call this script with the appropriate context.
EOF
        exit 1
    fi
    if ! docker volume inspect "${SUBSTRATE_ID_VOLUME}" >/dev/null 2>&1; then
        cat >&2 <<EOF
generate-keys.sh: refusing to run.
  ${SUBSTRATE_ID_FILE} claims substrate identity ${disk_id},
  but docker volume '${SUBSTRATE_ID_VOLUME}' does not exist.

  Run setup-linux.sh or setup-mac.sh; it will diagnose properly.
EOF
        exit 1
    fi
    volume_id=$(docker volume inspect "${SUBSTRATE_ID_VOLUME}" \
        --format "{{ index .Labels \"${SUBSTRATE_ID_LABEL_KEY}\" }}" 2>/dev/null || true)
    if [ "${disk_id}" != "${volume_id}" ]; then
        cat >&2 <<EOF
generate-keys.sh: refusing to run.
  Substrate identity mismatch:
    ${SUBSTRATE_ID_FILE}: ${disk_id}
    ${SUBSTRATE_ID_VOLUME} label: ${volume_id:-<none>}

  Run setup-linux.sh or setup-mac.sh; it will diagnose properly.
EOF
        exit 1
    fi
fi


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
