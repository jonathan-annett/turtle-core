#!/bin/bash
# infra/scripts/lib/validate-remote-host.sh
#
# Validates a remote-host registration spec for s010. Sourced (or
# executed) by setup-common.sh / bootstrap-remote-host.sh /
# add-platform-device.sh before any state mutation.
#
# Spec format:
#   <name>=<user>@<host>[:<port>]
#
# Constraints (per s010 brief 10.a):
#   - name:  ^[a-z][a-z0-9_-]{0,62}$  (lowercase, starts with a letter,
#            up to 63 chars, no whitespace).
#   - user:  any non-empty token without whitespace or '@' (let SSH
#            error on bad usernames; we just guard against the spec
#            grammar being unparseable).
#   - host:  hostname or IP, non-empty, no whitespace, no '/'.
#   - port:  optional, integer 1..65535. Defaults to 22.
#
# Names must be unique within one substrate. The check reads
# .substrate-state/remote-hosts.txt (if present) and refuses a name
# that already appears.
#
# Usage:
#   validate_remote_host_spec <spec>
#       Echoes "<name>|<user>|<host>|<port>" on success, exits non-zero
#       (with a diagnostic on stderr) on failure. Default port (22) is
#       always emitted explicitly.
#
#   validate_remote_host_spec_no_dup_check <spec>
#       Same as above but skips the duplicate-name check. Used by
#       bootstrap-remote-host.sh during a multi-host setup pass where
#       names are validated for uniqueness against the in-memory list
#       already, and the state file is mutated mid-pass.

_vrh_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE_HOST_REPO_ROOT="${REMOTE_HOST_REPO_ROOT:-$(cd "${_vrh_lib_dir}/../../.." && pwd)}"

_vrh_die() {
    echo "[validate-remote-host] $*" >&2
    return 2
}

_vrh_parse() {
    # Splits "<name>=<user>@<host>[:<port>]" into name|user|host|port.
    # Echoes the four-field form on success; non-zero on failure.
    local spec="$1"

    case "${spec}" in
        *=*) ;;
        *)
            _vrh_die "spec '${spec}': missing '=' between <name> and <user>@<host>"
            return 1 ;;
    esac

    local name="${spec%%=*}"
    local rest="${spec#*=}"

    if [ -z "${name}" ]; then
        _vrh_die "spec '${spec}': empty <name>"
        return 1
    fi
    if ! printf '%s' "${name}" | grep -qE '^[a-z][a-z0-9_-]{0,62}$'; then
        _vrh_die "spec '${spec}': invalid name '${name}' (must match ^[a-z][a-z0-9_-]{0,62}$)"
        return 1
    fi

    case "${rest}" in
        *@*) ;;
        *)
            _vrh_die "spec '${spec}': missing '@' between <user> and <host>"
            return 1 ;;
    esac

    local user="${rest%%@*}"
    local hostport="${rest#*@}"
    if [ -z "${user}" ]; then
        _vrh_die "spec '${spec}': empty <user>"
        return 1
    fi
    if printf '%s' "${user}" | grep -qE '[[:space:]/]'; then
        _vrh_die "spec '${spec}': invalid <user> '${user}' (whitespace or '/')"
        return 1
    fi

    local host port
    case "${hostport}" in
        *:*)
            host="${hostport%:*}"
            port="${hostport##*:}"
            ;;
        *)
            host="${hostport}"
            port="22"
            ;;
    esac

    if [ -z "${host}" ]; then
        _vrh_die "spec '${spec}': empty <host>"
        return 1
    fi
    if printf '%s' "${host}" | grep -qE '[[:space:]/]'; then
        _vrh_die "spec '${spec}': invalid <host> '${host}' (whitespace or '/')"
        return 1
    fi
    if ! printf '%s' "${port}" | grep -qE '^[0-9]+$'; then
        _vrh_die "spec '${spec}': port '${port}' is not an integer"
        return 1
    fi
    if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
        _vrh_die "spec '${spec}': port '${port}' out of range 1..65535"
        return 1
    fi

    printf '%s|%s|%s|%s' "${name}" "${user}" "${host}" "${port}"
    return 0
}

validate_remote_host_spec_no_dup_check() {
    _vrh_parse "$1"
}

validate_remote_host_spec() {
    local spec="$1"
    local parsed rc
    parsed=$(_vrh_parse "${spec}")
    rc=$?
    if [ "${rc}" -ne 0 ]; then
        return "${rc}"
    fi
    local name="${parsed%%|*}"
    local state_file="${REMOTE_HOST_REPO_ROOT}/.substrate-state/remote-hosts.txt"
    if [ -f "${state_file}" ]; then
        # State file is TSV: <name>\t<user>\t<host>\t<port>.
        if awk -F'\t' -v n="${name}" '$1==n {found=1} END{exit !found}' "${state_file}"; then
            _vrh_die "spec '${spec}': name '${name}' is already registered in ${state_file}"
            return 1
        fi
    fi
    printf '%s' "${parsed}"
    return 0
}

# Direct-execution mode for ad-hoc validation:
#   bash infra/scripts/lib/validate-remote-host.sh '<spec>'
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 '<name>=<user>@<host>[:<port>]'" >&2
        exit 2
    fi
    if out=$(validate_remote_host_spec "$1"); then
        printf '%s\n' "${out}"
        exit 0
    else
        exit 1
    fi
fi
