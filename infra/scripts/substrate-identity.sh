#!/bin/bash
# Substrate-identity helpers. Source-only — no side effects on source.
#
# Defines the .substrate-id sentinel + claude-state-architect volume label
# pairing and the gate function used by setup-{linux,mac}.sh.
#
# See methodology/deployment-docker.md §3.5 for the model.

# Constants. Kept here so other scripts (generate-keys.sh, setup-common.sh,
# the adopt path) all reference the same values.
SUBSTRATE_ID_VOLUME="claude-state-architect"
SUBSTRATE_ID_LABEL_KEY="app.turtle-core.substrate-id"

# Resolve a sane repo root. Callers may already have set repo_root; if so,
# don't clobber it.
if [ -z "${repo_root:-}" ]; then
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
SUBSTRATE_ID_FILE="${repo_root}/.substrate-id"

# Generate a fresh UUID v4 in lower-case canonical form. Tries uuidgen first
# (default on macOS, available on most Linux via uuid-runtime), then falls
# back to /proc/sys/kernel/random/uuid (always present on Linux). Dies if
# neither is available.
substrate_id_generate() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return 0
    fi
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    echo "substrate-identity: no UUID source available (uuidgen missing and /proc/sys/kernel/random/uuid unreadable)" >&2
    return 1
}

# Validate that a string looks like a canonical UUID v4. Lowercase only —
# we always normalise on write.
substrate_id_is_valid() {
    local id="$1"
    printf '%s' "${id}" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
}

# Read the disk sentinel. Outputs the UUID on stdout, or empty string if
# the file is absent. Validates UUID format if the file exists; dies on
# malformed content.
substrate_id_read_disk() {
    if [ ! -f "${SUBSTRATE_ID_FILE}" ]; then
        return 0
    fi
    local id
    id=$(head -n 1 "${SUBSTRATE_ID_FILE}" | tr -d '[:space:]')
    if ! substrate_id_is_valid "${id}"; then
        echo "substrate-identity: ${SUBSTRATE_ID_FILE} exists but does not contain a valid UUID v4." >&2
        echo "substrate-identity: contents: '${id}'" >&2
        return 1
    fi
    printf '%s\n' "${id}"
}

# Read the volume label. Outputs the UUID on stdout (empty if no label or
# volume absent). Sets exit code 0 if volume exists, 1 if not.
substrate_id_read_volume() {
    if ! docker volume inspect "${SUBSTRATE_ID_VOLUME}" >/dev/null 2>&1; then
        return 1
    fi
    docker volume inspect "${SUBSTRATE_ID_VOLUME}" \
        --format "{{ index .Labels \"${SUBSTRATE_ID_LABEL_KEY}\" }}" 2>/dev/null \
        || true
    return 0
}

# Write the sentinel file with mode 0644. If the script was invoked under
# sudo, hand ownership back to the invoking user so the file is editable
# by the human who runs the script.
substrate_id_write_disk() {
    local id="$1"
    if ! substrate_id_is_valid "${id}"; then
        echo "substrate-identity: refusing to write malformed UUID '${id}' to ${SUBSTRATE_ID_FILE}" >&2
        return 1
    fi
    umask 022
    printf '%s\n' "${id}" > "${SUBSTRATE_ID_FILE}"
    chmod 644 "${SUBSTRATE_ID_FILE}"
    if [ -n "${SUDO_UID:-}" ] && [ "${SUDO_UID}" != "0" ]; then
        chown "${SUDO_UID}:${SUDO_GID:-${SUDO_UID}}" "${SUBSTRATE_ID_FILE}"
    fi
}

# Main gate. Reads disk and volume state, branches on the five-outcome
# matrix from deployment-docker.md §3.5, and either:
#   - exits the calling script with a fatal diagnostic (mismatch cases), or
#   - exports SUBSTRATE_ID and SUBSTRATE_ID_FRESH_INSTALL=0|1 for the
#     caller's downstream use.
# The caller is expected to have a `die()` function in scope; if not, we
# fall back to printing to stderr and `exit 1`.
substrate_id_gate() {
    local _die
    if declare -F die >/dev/null 2>&1; then
        _die() { die "$@"; }
    else
        _die() { printf '[substrate-identity] FATAL: %s\n' "$*" >&2; exit 1; }
    fi

    local disk_id
    disk_id=$(substrate_id_read_disk) || _die "could not read ${SUBSTRATE_ID_FILE}; see message above."

    local volume_present=0
    local volume_id=""
    if docker volume inspect "${SUBSTRATE_ID_VOLUME}" >/dev/null 2>&1; then
        volume_present=1
        volume_id=$(docker volume inspect "${SUBSTRATE_ID_VOLUME}" \
            --format "{{ index .Labels \"${SUBSTRATE_ID_LABEL_KEY}\" }}" 2>/dev/null || true)
    fi

    # Case 1: nothing on disk, nothing in Docker → fresh install.
    if [ -z "${disk_id}" ] && [ "${volume_present}" -eq 0 ]; then
        local new_id
        new_id=$(substrate_id_generate) || _die "could not generate a UUID; install 'uuid-runtime' or run on a Linux host with /proc/sys/kernel/random/uuid."
        substrate_id_write_disk "${new_id}" || _die "could not write ${SUBSTRATE_ID_FILE}."
        echo "[substrate-identity] Fresh install. Generated substrate identity: ${new_id}"
        echo "[substrate-identity] Wrote ${SUBSTRATE_ID_FILE}; ${SUBSTRATE_ID_VOLUME} volume will be labelled with this UUID."
        export SUBSTRATE_ID="${new_id}"
        export SUBSTRATE_ID_FRESH_INSTALL=1
        return 0
    fi

    # Case 2: disk empty, volume present → tree is naive of running substrate.
    if [ -z "${disk_id}" ] && [ "${volume_present}" -eq 1 ]; then
        _die "$(cat <<EOF
docker volume '${SUBSTRATE_ID_VOLUME}' exists, but this tree has no .substrate-id.
The tree does not know about the substrate that is in Docker state — running
setup here would silently regenerate per-role keys and fight the running substrate
for the same volumes.

Diagnose the live substrate's identity:
    docker volume inspect ${SUBSTRATE_ID_VOLUME} --format '{{json .Labels}}'

Resolve by ONE of:
  (a) './setup-linux.sh --adopt-existing-substrate' (or setup-mac.sh) — IF AND
      ONLY IF you are sure this tree corresponds to the running Docker substrate.
  (b) Tear down the live substrate's Docker state, then re-run setup for a
      fresh install:
          docker compose down -v --remove-orphans
  (c) Switch to the correct tree (the one whose .substrate-id matches the volume).
EOF
)"
    fi

    # Case 3: disk present, volume absent → tree describes a substrate with no
    # live Docker state.
    if [ -n "${disk_id}" ] && [ "${volume_present}" -eq 0 ]; then
        _die "$(cat <<EOF
${SUBSTRATE_ID_FILE} claims substrate identity:
    ${disk_id}
but docker volume '${SUBSTRATE_ID_VOLUME}' does not exist. The tree describes a
substrate that has no live Docker state on this host.

Likely causes:
  - 'docker compose down -v' (or similar) was run, removing the volume.
  - You are setting up on a different host than the one that ran the original setup.
  - The tree was restored from backup but the volumes were not.

Resolve by ONE of:
  (a) Re-attach this tree to a fresh substrate:
          rm .substrate-id
          ./setup-linux.sh        # (or setup-mac.sh)
      This generates a new substrate identity.
  (b) Restore the matching architect volume from backup (with its
      ${SUBSTRATE_ID_LABEL_KEY} label intact), then re-run setup.
EOF
)"
    fi

    # From here on: both disk_id and volume are present.

    # Case 4: volume present but unlabelled → predates the identity mechanism.
    if [ -z "${volume_id}" ]; then
        _die "$(cat <<EOF
${SUBSTRATE_ID_FILE} claims substrate identity:
    ${disk_id}
but docker volume '${SUBSTRATE_ID_VOLUME}' has no '${SUBSTRATE_ID_LABEL_KEY}' label.

This usually means the volume predates the substrate-identity mechanism and was
never adopted. Run:
    ./setup-linux.sh --adopt-existing-substrate
  (or setup-mac.sh) to migrate. The flag refuses to run if .substrate-id already
  exists; remove it first if you genuinely intend to mint a new identity for
  this volume.
EOF
)"
    fi

    # Case 5: both present, mismatched.
    if [ "${disk_id}" != "${volume_id}" ]; then
        _die "$(cat <<EOF
substrate identity mismatch:

    ${SUBSTRATE_ID_FILE} (disk) : ${disk_id}
    ${SUBSTRATE_ID_VOLUME} volume : ${volume_id}

The tree and the Docker state are from DIFFERENT substrates. Setup has been
refused; ANY action would have desynced one side from the other.

Diagnose:
    docker volume inspect ${SUBSTRATE_ID_VOLUME} --format '{{json .Labels}}'

Resolve by ONE of:
  - Switch to the correct tree (whose .substrate-id matches the volume's label).
  - Tear down the wrong substrate's Docker state and start fresh:
        docker compose down -v --remove-orphans
  - If you are deliberately re-pointing this tree at a different substrate,
    first 'rm .substrate-id' and consider whether '--adopt-existing-substrate'
    fits the case.
EOF
)"
    fi

    # Case 6: both present, matching → ordinary re-setup.
    echo "[substrate-identity] Confirmed: ${disk_id}"
    export SUBSTRATE_ID="${disk_id}"
    export SUBSTRATE_ID_FRESH_INSTALL=0
    return 0
}
