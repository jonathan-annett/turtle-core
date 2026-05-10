#!/bin/bash
# infra/scripts/lib/remote-host-args.sh
#
# Argument-parsing helpers for the substrate's --remote-host /
# --add-remote-host flag pair (s010). Mirrors the API shape of
# infra/scripts/lib/platform-args.sh; sourced from setup-linux.sh,
# setup-mac.sh, and (indirectly via add-platform-device.sh) the
# running-substrate-extension pathway.
#
# Functions:
#   remote_host_args_init                Reset parsing state.
#   remote_host_args_consume <arg>       Try to consume one argv element.
#                                        Returns 0 if consumed; 1 if not
#                                        (caller should treat as unknown).
#   remote_host_args_finalize            Validate accumulated state, run
#                                        cross-checks. Exports:
#                                          SUBSTRATE_REMOTE_HOSTS
#                                          SUBSTRATE_ADD_REMOTE_HOST
#                                          SUBSTRATE_REMOTE_HOST_SUPPLIED
#   remote_host_args_help_block          Emit the help text for both
#                                        flags; called from each
#                                        entrypoint's --help handler.
#
# SUBSTRATE_REMOTE_HOSTS is exported as a comma-separated list of the
# original spec strings ("<name>=<user>@<host>[:<port>]"), preserving
# user-supplied syntax. The parsed/canonical form lives in
# .substrate-state/remote-hosts.txt after bootstrap-remote-host.sh
# runs.

_rh_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST_REPO_ROOT="${REMOTE_HOST_REPO_ROOT:-$(cd "${_rh_lib_dir}/../../.." && pwd)}"

# shellcheck source=infra/scripts/lib/validate-remote-host.sh
. "${_rh_lib_dir}/validate-remote-host.sh"

remote_host_args_init() {
    _rh_specs=()
    _rh_add_spec=""
    _rh_supplied=0
}

# Consume one argument from argv. Recognised forms:
#   --remote-host=<spec>[,<spec2>,...]
#   --add-remote-host=<spec>
# Returns 0 if consumed, 1 if the caller should keep handling.
remote_host_args_consume() {
    local arg="$1"
    case "${arg}" in
        --remote-host=*)
            _rh_supplied=1
            local val="${arg#--remote-host=}"
            local IFS=','
            for s in ${val}; do
                s="${s## }"; s="${s%% }"
                [ -n "${s}" ] && _rh_specs+=("${s}")
            done
            return 0
            ;;
        --add-remote-host=*)
            if [ -n "${_rh_add_spec}" ]; then
                echo "remote-host-args: --add-remote-host may be supplied at most once per invocation" >&2
                exit 2
            fi
            _rh_add_spec="${arg#--add-remote-host=}"
            return 0
            ;;
    esac
    return 1
}

# Validate accumulated state and export the env vars. Each spec must
# parse cleanly; duplicates within the argv set are refused (the
# existing-state-file check happens later, in bootstrap-remote-host.sh,
# because setup-time --remote-host re-runs are common and should be
# idempotent rather than a hard error).
remote_host_args_finalize() {
    # Validate each --remote-host spec for grammar; check for duplicate
    # names within the argv set.
    local seen_names=()
    if [ "${#_rh_specs[@]}" -gt 0 ]; then
        for spec in "${_rh_specs[@]}"; do
            local parsed
            if ! parsed=$(validate_remote_host_spec_no_dup_check "${spec}"); then
                echo "[setup] FATAL: --remote-host='${spec}' failed validation (see above)." >&2
                exit 1
            fi
            local name="${parsed%%|*}"
            for n in "${seen_names[@]:-}"; do
                if [ "${n}" = "${name}" ]; then
                    echo "[setup] FATAL: --remote-host: duplicate name '${name}' in argv set." >&2
                    exit 1
                fi
            done
            seen_names+=("${name}")
        done
    fi

    # Validate --add-remote-host similarly. The existing-state duplicate
    # check is the right one here (the running-substrate has a state file
    # already; we must not register a name that conflicts), so use the
    # full validator.
    if [ -n "${_rh_add_spec}" ]; then
        if ! validate_remote_host_spec "${_rh_add_spec}" >/dev/null; then
            echo "[setup] FATAL: --add-remote-host='${_rh_add_spec}' failed validation (see above)." >&2
            exit 1
        fi
    fi

    if [ "${#_rh_specs[@]}" -gt 0 ]; then
        SUBSTRATE_REMOTE_HOSTS=$(IFS=','; printf '%s' "${_rh_specs[*]}")
    else
        SUBSTRATE_REMOTE_HOSTS=""
    fi
    SUBSTRATE_ADD_REMOTE_HOST="${_rh_add_spec}"
    SUBSTRATE_REMOTE_HOST_SUPPLIED="${_rh_supplied}"
    export SUBSTRATE_REMOTE_HOSTS SUBSTRATE_ADD_REMOTE_HOST \
           SUBSTRATE_REMOTE_HOST_SUPPLIED

    if [ -n "${SUBSTRATE_REMOTE_HOSTS}" ]; then
        echo "[setup] SUBSTRATE_REMOTE_HOSTS=${SUBSTRATE_REMOTE_HOSTS}"
    fi
}

remote_host_args_help_block() {
    cat <<'EOF'
  --remote-host=<name>=<user>@<host>[:<port>][,<spec2>,...]
                     Register one or more named remote hosts at substrate
                     setup time (s010). For each spec the substrate
                     generates a per-host SSH keypair, installs the
                     public key on the target using your existing SSH
                     credentials, captures the host key, and verifies
                     that passwordless SSH+sudo + python3 work via the
                     substrate's key alone. Role containers (architect,
                     coder-daemon, auditor) then 'ssh <name> ...'
                     reaches the registered remote without further
                     setup.

                     Repeatable; multiple specs in one flag are
                     comma-separated. Names must match
                     ^[a-z][a-z0-9_-]{0,62}$ and be unique within the
                     substrate.

                     Prerequisite: passwordless SSH+sudo from your
                     shell to <user>@<host> before registering.

  --add-remote-host=<name>=<user>@<host>[:<port>]
                     One-shot remote-host registration on a running
                     substrate (s010). Refuses if any ephemeral
                     container is running; pass --force to override.
                     No image rebuild required (state files are live
                     bind-mounts; ssh-config is regenerated on the host
                     and propagates immediately).
EOF
}
