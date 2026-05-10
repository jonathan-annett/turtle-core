#!/bin/bash
# infra/scripts/bootstrap-remote-host.sh
#
# Performs the per-host registration flow for s010. Per the brief 10.c
# this is the substantive new code: it generates a per-host SSH keypair,
# captures the target's host key into the cumulative known-hosts file,
# installs the substrate's pubkey on the target using the OPERATOR's
# existing SSH credentials (one-time bootstrap; the substrate's key
# takes over thereafter), then verifies non-interactive substrate-key-
# only access works (passwordless SSH + sudo + python3).
#
# Two invocation modes:
#
#   bootstrap-remote-host.sh
#       Reads SUBSTRATE_REMOTE_HOSTS (comma-separated specs as exported
#       by remote_host_args_finalize) and bootstraps each. Skips empty.
#       Used by setup-common.sh during initial setup.
#
#   bootstrap-remote-host.sh <spec>
#       Bootstraps one spec ("<name>=<user>@<host>[:<port>]"). Used by
#       add-platform-device.sh when --add-remote-host is supplied on a
#       running substrate.
#
# Idempotent: re-running with the same registration set is a no-op
# (same key on the target, same known-hosts entry, same state-file line).
#
# Per-host steps (1..6):
#   1. Idempotency check — if the key, known-hosts entry, and substrate-
#      key-only ssh+sudo all already work, skip.
#   2. Generate ed25519 keypair under infra/keys/remote-hosts/<name>/.
#   3. Capture target host key via ssh-keyscan; append to known-hosts.
#   4. Install substrate pubkey on the target using the operator's loaded
#      SSH credentials. BatchMode=yes — fails fast if passwordless SSH
#      from the operator's shell isn't already set up.
#   5. Re-verify with -F /dev/null + IdentitiesOnly=yes so we know the
#      substrate's key alone (no agent forwarding) is sufficient. Also
#      checks 'sudo -n true' and 'python3 --version' on the target.
#   6. Append "<name>\t<user>\t<host>\t<port>" to remote-hosts.txt.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

state_dir="${repo_root}/.substrate-state"
keys_dir="${repo_root}/infra/keys/remote-hosts"
mkdir -p "${state_dir}"
mkdir -p "${keys_dir}"
chmod 0700 "${keys_dir}"

# shellcheck source=infra/scripts/lib/validate-remote-host.sh
. "${repo_root}/infra/scripts/lib/validate-remote-host.sh"

log()  { printf '[bootstrap-remote-host] %s\n' "$*"; }
warn() { printf '[bootstrap-remote-host] WARNING: %s\n' "$*" >&2; }
die()  { printf '[bootstrap-remote-host] FATAL: %s\n' "$*" >&2; exit 1; }

# Touch the cumulative known-hosts file so subsequent ssh -o
# UserKnownHostsFile=<path> commands have a writable target. The empty
# file is fine (StrictHostKeyChecking=accept-new will append on first
# contact; the keyscan in step 3 also adds the entry explicitly).
known_hosts="${state_dir}/known-hosts"
touch "${known_hosts}"
chmod 0644 "${known_hosts}"

# ---------------------------------------------------------------------------
# Step 1: idempotency check.
#
# We consider a host "fully registered" when:
#   - infra/keys/remote-hosts/<name>/id_ed25519 exists,
#   - the known-hosts file already contains a line for this host:port,
#   - and a probe ssh using the substrate key alone (no agent fallback)
#     succeeds with 'sudo -n true' on the target.
#
# All three must hold; partial state means we re-run the bootstrap to
# repair. Echoes "yes" or "no" to stdout.
# ---------------------------------------------------------------------------
already_registered() {
    local name="$1" user="$2" host="$3" port="$4"
    local key="${keys_dir}/${name}/id_ed25519"
    [ -f "${key}" ] || { echo no; return; }

    # known-hosts entries are either "<host> ssh-..." or, when port ≠ 22,
    # "[<host>]:<port> ssh-...". grep -F is sufficient because both
    # forms are literal substrings.
    local kh_marker
    if [ "${port}" = "22" ]; then
        kh_marker="${host} "
    else
        kh_marker="[${host}]:${port} "
    fi
    if ! grep -qF "${kh_marker}" "${known_hosts}" 2>/dev/null; then
        echo no
        return
    fi

    if ssh -F /dev/null \
           -i "${key}" \
           -o IdentitiesOnly=yes \
           -o BatchMode=yes \
           -o StrictHostKeyChecking=yes \
           -o UserKnownHostsFile="${known_hosts}" \
           -o ConnectTimeout=5 \
           -p "${port}" "${user}@${host}" 'sudo -n true' \
           >/dev/null 2>&1; then
        echo yes
    else
        echo no
    fi
}

# ---------------------------------------------------------------------------
# Steps 2..6 for a single host. Idempotency-safe: each step is either
# pure-create (mkdir/touch/append-if-missing) or guarded.
# ---------------------------------------------------------------------------
bootstrap_one() {
    local spec="$1"
    local parsed
    parsed=$(validate_remote_host_spec_no_dup_check "${spec}")
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        die "spec '${spec}' is invalid; nothing changed."
    fi

    local name user host port
    IFS='|' read -r name user host port <<<"${parsed}"

    # Step 1
    log "${name}: ${user}@${host}:${port}"
    if [ "$(already_registered "${name}" "${user}" "${host}" "${port}")" = "yes" ]; then
        log "${name}: already registered, skipping"
        # Even when skipping the substantive steps, ensure the state
        # file line is present (a partial state-file truncation must
        # still resurface on a re-run).
        ensure_state_line "${name}" "${user}" "${host}" "${port}"
        return 0
    fi

    # Step 2 — generate keypair
    local host_keys_dir="${keys_dir}/${name}"
    mkdir -p "${host_keys_dir}"
    chmod 0700 "${host_keys_dir}"
    local privkey="${host_keys_dir}/id_ed25519"
    local pubkey="${host_keys_dir}/id_ed25519.pub"
    if [ ! -f "${privkey}" ]; then
        log "${name}: generating ed25519 keypair → ${privkey}"
        ssh-keygen -t ed25519 -N "" -q \
            -f "${privkey}" \
            -C "turtle-core-substrate@${name}" >/dev/null
        chmod 0600 "${privkey}"
        chmod 0644 "${pubkey}"
    else
        log "${name}: keypair already present"
    fi

    # Step 3 — capture target host key
    log "${name}: capturing host key via ssh-keyscan -p ${port} ${host}"
    local scan
    scan=$(ssh-keyscan -p "${port}" -t ed25519,rsa "${host}" 2>/dev/null || true)
    if [ -z "${scan}" ]; then
        die "${name}: ssh-keyscan returned no host key — is ${host}:${port} reachable?"
    fi
    # ssh-keyscan emits raw "<host> ssh-...". When port ≠ 22 the
    # canonical known-hosts form is "[<host>]:<port> ssh-..."; rewrite.
    if [ "${port}" != "22" ]; then
        scan=$(printf '%s\n' "${scan}" | sed -E "s|^${host//./\\.} |[${host}]:${port} |")
    fi
    # Append each new line, deduping against existing content.
    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        if ! grep -qxF "${line}" "${known_hosts}" 2>/dev/null; then
            printf '%s\n' "${line}" >> "${known_hosts}"
        fi
    done <<<"${scan}"

    # Step 4 — install substrate pubkey on the target using the operator's
    # existing SSH creds (BatchMode=yes — fails fast if passwordless SSH
    # isn't already configured). NO agent forwarding; we use whatever
    # identity the operator's loaded ssh-agent / ~/.ssh/id_* provides.
    local pubkey_line
    pubkey_line=$(cat "${pubkey}")
    log "${name}: installing substrate pubkey on ${user}@${host} (using operator credentials)"
    if ! ssh -o BatchMode=yes \
             -o StrictHostKeyChecking=accept-new \
             -o UserKnownHostsFile="${known_hosts}" \
             -o ConnectTimeout=10 \
             -p "${port}" "${user}@${host}" \
             "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; chmod 0600 ~/.ssh/authorized_keys; grep -q -F '$(printf '%s' "${pubkey_line}" | sed "s/'/'\\\\''/g")' ~/.ssh/authorized_keys || printf '%s\n' '$(printf '%s' "${pubkey_line}" | sed "s/'/'\\\\''/g")' >> ~/.ssh/authorized_keys" \
             >/dev/null; then
        cat >&2 <<EOF
[bootstrap-remote-host] FATAL: ${name}: could not install pubkey on ${user}@${host}.
[bootstrap-remote-host]
[bootstrap-remote-host]   The substrate uses your operator credentials (loaded ssh-agent
[bootstrap-remote-host]   identity, or ~/.ssh/id_*) for this one-time bootstrap, with
[bootstrap-remote-host]   BatchMode=yes — no password prompt.
[bootstrap-remote-host]
[bootstrap-remote-host]   Set up passwordless SSH first:
[bootstrap-remote-host]       ssh-copy-id ${user}@${host}
[bootstrap-remote-host]       ssh ${user}@${host} 'sudo -n true'  # confirm sudo works
[bootstrap-remote-host]
[bootstrap-remote-host]   Then re-run setup. The local substrate keypair has already
[bootstrap-remote-host]   been generated; it will be reused on the next attempt.
EOF
        exit 1
    fi

    # Step 5 — re-verify using only the substrate key (no agent forwarding).
    log "${name}: verifying substrate-key-only access (sudo -n + python3)"
    local verify_out verify_rc
    verify_out=$(ssh -F /dev/null \
                     -i "${privkey}" \
                     -o IdentitiesOnly=yes \
                     -o BatchMode=yes \
                     -o StrictHostKeyChecking=yes \
                     -o UserKnownHostsFile="${known_hosts}" \
                     -o ConnectTimeout=10 \
                     -p "${port}" "${user}@${host}" \
                     'sudo -n true >/dev/null 2>&1 && echo SUDO_OK; python3 --version 2>&1 || echo PYTHON3_MISSING' \
                     2>&1)
    verify_rc=$?
    if [ "${verify_rc}" -ne 0 ]; then
        die "${name}: substrate-key-only ssh failed (rc=${verify_rc}). Output:
${verify_out}"
    fi
    if ! printf '%s' "${verify_out}" | grep -qx 'SUDO_OK'; then
        die "${name}: remote user '${user}' lacks passwordless sudo. Verification output:
${verify_out}"
    fi
    if printf '%s' "${verify_out}" | grep -qx 'PYTHON3_MISSING'; then
        die "${name}: python3 not found on remote. Install it (apt/yum/...) and re-run setup. Verification output:
${verify_out}"
    fi
    if ! printf '%s' "${verify_out}" | grep -q '^Python 3'; then
        warn "${name}: python3 reported an unexpected version banner: ${verify_out}"
    fi

    # Step 6 — append to state file.
    ensure_state_line "${name}" "${user}" "${host}" "${port}"
    log "${name}: registered."
}

# ---------------------------------------------------------------------------
# State-file maintenance. The TSV format is documented in 10.a:
#   <name>\t<user>\t<host>\t<port>
# Append the line if missing. Setup-common.sh's pattern is to regenerate
# platforms.txt / devices.txt every run; for remote-hosts.txt that would
# lose registrations across re-runs that don't re-supply --remote-host
# (the keys and known-hosts entries are durable on the host either way,
# so the state file should be too). We append-if-missing instead.
# ---------------------------------------------------------------------------
ensure_state_line() {
    local name="$1" user="$2" host="$3" port="$4"
    local state_file="${state_dir}/remote-hosts.txt"
    touch "${state_file}"
    if awk -F'\t' -v n="${name}" '$1==n {found=1} END{exit !found}' "${state_file}"; then
        # Already present — verify the rest of the line matches; if not
        # rewrite (the operator may have edited the spec by re-running
        # with a different user/host).
        local existing
        existing=$(awk -F'\t' -v n="${name}" '$1==n {print $0}' "${state_file}")
        local desired
        printf -v desired '%s\t%s\t%s\t%s' "${name}" "${user}" "${host}" "${port}"
        if [ "${existing}" != "${desired}" ]; then
            log "${name}: updating state-file line (was: ${existing})"
            awk -F'\t' -v n="${name}" '$1!=n' "${state_file}" > "${state_file}.tmp"
            mv "${state_file}.tmp" "${state_file}"
            printf '%s\n' "${desired}" >> "${state_file}"
        fi
    else
        printf '%s\t%s\t%s\t%s\n' "${name}" "${user}" "${host}" "${port}" >> "${state_file}"
    fi
}

# ---------------------------------------------------------------------------
# Drive: argv-spec mode (single host) vs. env-driven mode (loop over
# SUBSTRATE_REMOTE_HOSTS).
# ---------------------------------------------------------------------------
if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    bootstrap_one "$1"
    exit 0
fi

if [ -z "${SUBSTRATE_REMOTE_HOSTS:-}" ]; then
    log "no remote hosts to bootstrap (SUBSTRATE_REMOTE_HOSTS empty)"
    exit 0
fi

IFS=',' read -ra _specs <<<"${SUBSTRATE_REMOTE_HOSTS}"
for spec in "${_specs[@]}"; do
    spec="${spec## }"; spec="${spec%% }"
    [ -z "${spec}" ] && continue
    bootstrap_one "${spec}"
done
