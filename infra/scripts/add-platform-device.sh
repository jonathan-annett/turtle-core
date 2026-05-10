#!/bin/bash
# infra/scripts/add-platform-device.sh
#
# One-shot extension of a running substrate (s009 9.e). Invoked by
# setup-linux.sh / setup-mac.sh when --add-platform=<name> and/or
# --add-device=<host-path>[,...] is supplied. Reads the request from
# the SUBSTRATE_ADD_PLATFORM, SUBSTRATE_ADD_DEVICES, and SUBSTRATE_FORCE
# env vars (exported by platform_args_finalize in
# infra/scripts/lib/platform-args.sh).
#
# Behaviour:
#
#   --add-platform=<name>:
#     1. Validate the platform YAML (schema).
#     2. Pre-flight: refuse if any ephemeral container is running OR
#        any section/* branch on origin has commits ahead of main.
#        Skip with --force.
#     3. Re-render Dockerfile.generated for both roles with the new
#        platform list (= current ∪ {new}).
#     4. Rebuild coder-daemon + auditor (architect / git-server are
#        unaffected).
#     5. Run setup-time verify for the new platform.
#     6. Update .substrate-state/platforms.txt to the new list.
#     7. If the new platform requires a device and no matching device
#        is mapped, warn (per design call 5).
#     8. Print a hint about SHARED-STATE.md.
#
#   --add-device=<host-path>[,...]:
#     1. Validate each path exists on the host (already done by
#        platform_args_consume / finalize).
#     2. Pre-flight: refuse only on running containers (not on pending
#        sections — adding a device cannot invalidate in-progress work).
#     3. Append to .substrate-state/devices.txt.
#     4. Re-render docker-compose.override.yml so subsequent compose
#        runs see the device.
#     5. No image rebuild required (devices are runtime, not build-time).
#
#   --add-remote-host=<spec>  (s010 10.e):
#     1. Validate the spec (validate-remote-host.sh).
#     2. Refuse if <name> is already registered (validator catches
#        this via the state-file duplicate check).
#     3. Pre-flight: refuse only on running containers; ssh-config is
#        a live bind mount so a quiescent moment avoids surprises.
#        Skip with --force.
#     4. Run bootstrap-remote-host.sh for the new spec.
#     5. Re-render .substrate-state/ssh-config (and the per-role
#        copies); running containers see the change immediately.
#     6. No image rebuild required.
#
# All three may be combined in one invocation; --add-platform runs
# first (image rebuild), then --add-device (override regen), then
# --add-remote-host (bootstrap + render).

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

log()  { printf '[add] %s\n' "$*"; }
warn() { printf '[add] WARNING: %s\n' "$*" >&2; }
die()  { printf '[add] FATAL: %s\n' "$*" >&2; exit 1; }

state_dir="${repo_root}/.substrate-state"
mkdir -p "${state_dir}"

# shellcheck source=infra/scripts/lib/yaml.sh
. "${repo_root}/infra/scripts/lib/yaml.sh"
# shellcheck source=infra/scripts/lib/validate-platform.sh
. "${repo_root}/infra/scripts/lib/validate-platform.sh"
# shellcheck source=infra/scripts/lib/validate-remote-host.sh
. "${repo_root}/infra/scripts/lib/validate-remote-host.sh"

# ---------------------------------------------------------------------------
# Pre-flight check (a): running ephemeral containers. We look for any
# container whose image is one of the role images. This catches
# planners / coders / auditors regardless of compose project namespace.
# ---------------------------------------------------------------------------
running_role_containers() {
    local out=()
    # ROLE_IMAGE_PATTERNS is colon-separated; each entry is a literal
    # "<image>:<tag>" (or just "<image>" — defaults to ":latest"). The
    # default scans the canonical role image tags; the substrate end-
    # to-end test overrides it to scan its own scratch-tagged images.
    local patterns="${ROLE_IMAGE_PATTERNS:-agent-planner:latest:agent-coder-daemon:latest:agent-auditor:latest}"
    # Trickier than usual to split because the entries themselves
    # contain ':'. Use a space-separated alternative if the env var is
    # set with spaces; otherwise interpret as the canonical default.
    local images=()
    if [ -n "${ROLE_IMAGE_PATTERNS:-}" ]; then
        IFS=' ' read -ra images <<<"${ROLE_IMAGE_PATTERNS}"
    else
        images=(agent-planner:latest agent-coder-daemon:latest agent-auditor:latest)
    fi
    for img in "${images[@]}"; do
        # Default to :latest if no tag specified.
        case "${img}" in
            *:*) ;;
            *)   img="${img}:latest" ;;
        esac
        local cids
        cids=$(docker ps --format '{{.ID}} {{.Image}} {{.Names}}' | awk -v img="${img}" '$2==img {print $3":"$1}')
        if [ -n "${cids}" ]; then
            while IFS= read -r line; do
                [ -n "${line}" ] && out+=("${line}")
            done <<<"${cids}"
        fi
    done
    if [ "${#out[@]}" -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Pre-flight check (b): section/* branches with un-merged commits on
# origin. We query the git-server container directly (it holds the
# bare repo). If git-server isn't running, we can't determine state —
# fail safe and refuse (the human can --force).
# ---------------------------------------------------------------------------
pending_section_branches() {
    if ! docker inspect -f '{{.State.Running}}' "${GIT_SERVER_CONTAINER:-agent-git-server}" 2>/dev/null | grep -q '^true$'; then
        echo "GIT_SERVER_DOWN"
        return
    fi
    local out=()
    while IFS= read -r ref; do
        [ -z "${ref}" ] && continue
        local short="${ref#refs/heads/}"
        local count
        count=$(docker exec "${GIT_SERVER_CONTAINER:-agent-git-server}" git --git-dir=/srv/git/main.git \
            rev-list --count "main..${short}" 2>/dev/null || echo 0)
        if [ "${count}" -gt 0 ] 2>/dev/null; then
            out+=("${short} (+${count} commits)")
        fi
    done < <(docker exec "${GIT_SERVER_CONTAINER:-agent-git-server}" git --git-dir=/srv/git/main.git \
        for-each-ref --format='%(refname)' refs/heads/section/ 2>/dev/null)
    if [ "${#out[@]}" -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Read current platforms / devices from state file. Falls back to
# 'default' / empty if missing (clean substrate).
# ---------------------------------------------------------------------------
read_state_list() {
    local file="$1"
    if [ -f "${file}" ]; then
        # tr -s collapses repeated commas (defensive); paste joins lines.
        paste -sd ',' "${file}" 2>/dev/null | tr -s ',' || true
    fi
}

current_platforms=$(read_state_list "${state_dir}/platforms.txt")
[ -z "${current_platforms}" ] && current_platforms="default"
current_devices=$(read_state_list "${state_dir}/devices.txt")

# ---------------------------------------------------------------------------
# --add-platform branch
# ---------------------------------------------------------------------------
do_add_platform() {
    local new="${SUBSTRATE_ADD_PLATFORM}"
    log "--add-platform=${new}"

    if ! validate_platform "${new}"; then
        die "platform '${new}' failed schema validation; nothing changed."
    fi

    # Compose new platform list. Drop 'default' if other entries exist;
    # drop duplicate of <new>.
    local existing=()
    IFS=',' read -ra _existing <<< "${current_platforms}"
    for p in "${_existing[@]}"; do
        [ -z "${p}" ] && continue
        [ "${p}" = "default" ] && continue
        [ "${p}" = "${new}" ] && continue
        existing+=("${p}")
    done
    existing+=("${new}")
    local new_csv
    new_csv=$(IFS=','; printf '%s' "${existing[*]}")

    log "current platforms: ${current_platforms}"
    log "new platforms:     ${new_csv}"

    # Pre-flight (a)
    local running
    running=$(running_role_containers)
    # Pre-flight (b)
    local pending
    pending=$(pending_section_branches)

    if [ "${SUBSTRATE_FORCE:-0}" != "1" ]; then
        if [ -n "${running}" ]; then
            echo "[add] FATAL: refuse --add-platform — ephemeral containers are running:" >&2
            printf '  - %s\n' ${running} >&2
            echo "[add] tear them down first, or pass --force to override." >&2
            exit 1
        fi
        if [ "${pending}" = "GIT_SERVER_DOWN" ]; then
            die "git-server is not running; cannot inspect section branches. Bring git-server up first ('docker compose up -d git-server') or pass --force."
        fi
        if [ -n "${pending}" ]; then
            echo "[add] FATAL: refuse --add-platform — section/* branches have unmerged commits:" >&2
            printf '  - %s\n' ${pending} >&2
            echo "[add] merge or discard them first, or pass --force to override." >&2
            exit 1
        fi
    else
        warn "--force: skipping pre-flight checks (running=$([ -n "$running" ] && echo yes || echo no), pending=$([ "$pending" = "GIT_SERVER_DOWN" ] && echo unknown || ([ -n "$pending" ] && echo yes || echo no)))."
    fi

    # Re-render Dockerfiles with new platform list.
    log "Re-rendering Dockerfiles for ${new_csv}..."
    "${repo_root}/infra/scripts/render-dockerfile.sh" coder-daemon "${new_csv}"
    "${repo_root}/infra/scripts/render-dockerfile.sh" auditor       "${new_csv}"

    # Rebuild affected role images. agent-base is unaffected (renderer
    # doesn't touch infra/base) — skip the agent-base build.
    log "Rebuilding coder-daemon and auditor images..."
    docker compose --profile ephemeral build coder-daemon auditor

    # Setup-time verify for the NEW platform only (existing platforms
    # were verified at their own --platform / --add-platform time).
    log "Verifying ${new} toolchain in role images..."
    local verify_failed=()
    local yaml_file="${repo_root}/methodology/platforms/${new}.yaml"
    for role in coder-daemon auditor; do
        local image="agent-${role}:latest"
        local verify_json
        verify_json=$(docker run --rm \
            -v "${repo_root}/methodology/platforms:/p:ro" \
            mikefarah/yq:4 -o=json ".roles.\"${role}\".verify // []" \
            "/p/${new}.yaml" 2>/dev/null || echo "[]")
        local cmds
        cmds=$(printf '%s' "${verify_json}" | python3 -c '
import json, sys
for c in json.loads(sys.stdin.read()):
    print(c)
')
        [ -z "${cmds}" ] && continue
        while IFS= read -r cmd; do
            [ -z "${cmd}" ] && continue
            if docker run --rm --entrypoint bash "${image}" -lc "${cmd}" \
                >/dev/null 2>&1; then
                log "  [verify ok] ${new}/${role}: ${cmd}"
            else
                log "  [verify FAIL] ${new}/${role}: ${cmd}"
                verify_failed+=("${new}/${role}: ${cmd}")
            fi
        done <<<"${cmds}"
    done
    if [ "${#verify_failed[@]}" -gt 0 ]; then
        echo "[add] FATAL: setup-time verify failed for ${new}; substrate state file NOT updated." >&2
        for entry in "${verify_failed[@]}"; do
            echo "  - ${entry}" >&2
        done
        echo "[add] images have been rebuilt with ${new} but the state file still reflects" >&2
        echo "[add] the previous platform list. Re-run with the same --add-platform flag" >&2
        echo "[add] after fixing the underlying cause." >&2
        exit 1
    fi

    # Update state file (only on full success).
    {
        for p in ${new_csv//,/ }; do
            [ -z "${p}" ] && continue
            echo "${p}"
        done
    } > "${state_dir}/platforms.txt"
    log "Updated ${state_dir}/platforms.txt → ${new_csv}"

    # Device-required warning if applicable.
    local req hint
    req=$(yaml_eval '.runtime.device_required // false' "${yaml_file}")
    if [ "${req}" = "true" ]; then
        if [ -z "${current_devices}" ] && [ -z "${SUBSTRATE_ADD_DEVICES:-}" ]; then
            hint=$(yaml_eval '.runtime.device_hint // ""' "${yaml_file}")
            warn "platform '${new}' declares runtime.device_required=true and no device is mapped."
            warn "  ${hint}"
            warn "  HIL test/flash/serial-monitor will not work until you add a device:"
            warn "    ./setup-linux.sh --add-device=<host-path>"
        fi
    fi

    cat <<EOF

Hint: SHARED-STATE.md should be updated by the architect to record
the new platform invariant. Attach to the architect:
    ./attach-architect.sh
and ask claude to refresh SHARED-STATE.md from /substrate/platforms.txt.

EOF
}

# ---------------------------------------------------------------------------
# --add-device branch
# ---------------------------------------------------------------------------
do_add_device() {
    local new_csv="${SUBSTRATE_ADD_DEVICES}"
    log "--add-device=${new_csv}"

    # Compose new device list. De-dup against the existing list.
    local existing=()
    if [ -n "${current_devices}" ]; then
        IFS=',' read -ra _existing <<< "${current_devices}"
        for d in "${_existing[@]}"; do
            [ -n "${d}" ] && existing+=("${d}")
        done
    fi
    IFS=',' read -ra _new <<< "${new_csv}"
    for d in "${_new[@]}"; do
        [ -z "${d}" ] && continue
        local seen=0
        for e in "${existing[@]:-}"; do
            [ "${e}" = "${d}" ] && seen=1 && break
        done
        [ "${seen}" -eq 0 ] && existing+=("${d}")
    done
    local merged
    merged=$(IFS=','; printf '%s' "${existing[*]}")

    log "current devices: ${current_devices:-(none)}"
    log "merged devices:  ${merged}"

    # Pre-flight (a) only — running ephemeral containers.
    if [ "${SUBSTRATE_FORCE:-0}" != "1" ]; then
        local running
        running=$(running_role_containers)
        if [ -n "${running}" ]; then
            echo "[add] FATAL: refuse --add-device — ephemeral containers are running:" >&2
            printf '  - %s\n' ${running} >&2
            echo "[add] tear them down first (so the device is wired into fresh runs), or pass --force." >&2
            exit 1
        fi
    fi

    # Re-render override file with the merged list.
    "${repo_root}/infra/scripts/render-device-override.sh" "${merged}"

    # Update state file.
    {
        for d in ${merged//,/ }; do
            [ -z "${d}" ] && continue
            echo "${d}"
        done
    } > "${state_dir}/devices.txt"
    log "Updated ${state_dir}/devices.txt → ${merged}"

    log "No image rebuild required (devices are runtime, not build-time)."
}

# ---------------------------------------------------------------------------
# --add-remote-host branch (s010 10.e)
# ---------------------------------------------------------------------------
do_add_remote_host() {
    local spec="${SUBSTRATE_ADD_REMOTE_HOST}"
    log "--add-remote-host=${spec}"

    # Validate. The full validator already checks the in-memory state
    # file for duplicates; remote_host_args_finalize ran it once at argv
    # time, but a re-check here protects against the unlikely case where
    # the file changed between argv parse and dispatch.
    if ! validate_remote_host_spec "${spec}" >/dev/null; then
        die "spec '${spec}' failed validation; nothing changed."
    fi

    # Pre-flight: refuse on any running ephemeral role container. The
    # ssh-config bind mount is live, so existing containers WOULD pick
    # up the new stanza — but a long-lived ssh control-master inside a
    # running container could hold an old config in memory, and a
    # quiescent state is conservative. --force skips.
    if [ "${SUBSTRATE_FORCE:-0}" != "1" ]; then
        local running
        running=$(running_role_containers)
        if [ -n "${running}" ]; then
            echo "[add] FATAL: refuse --add-remote-host — ephemeral containers are running:" >&2
            printf '  - %s\n' ${running} >&2
            echo "[add] tear them down first, or pass --force to override." >&2
            exit 1
        fi
    fi

    # Bootstrap (idempotent; runs the six-step flow from 10.c against
    # this single spec). This generates the per-host key, captures the
    # host key, installs the substrate pubkey on the target, and
    # appends to remote-hosts.txt.
    if ! "${repo_root}/infra/scripts/bootstrap-remote-host.sh" "${spec}"; then
        die "bootstrap failed for '${spec}' (see message above); state file unchanged."
    fi

    # Re-render ssh-config so running containers (and any new ones
    # spawned by commission-pair / audit) see the new stanza.
    "${repo_root}/infra/scripts/render-ssh-config.sh"

    local name="${spec%%=*}"
    log "--add-remote-host: ${name} registered. Running containers see the new stanza"
    log "  via the live bind-mount of .substrate-state/ssh-config and infra/keys/<role>/config."
    log "  No image rebuild, no compose restart."
}

# ---------------------------------------------------------------------------
# Drive
# ---------------------------------------------------------------------------
yaml_pull

if [ -n "${SUBSTRATE_ADD_PLATFORM:-}" ]; then
    do_add_platform
fi
if [ -n "${SUBSTRATE_ADD_DEVICES:-}" ]; then
    do_add_device
fi
if [ -n "${SUBSTRATE_ADD_REMOTE_HOST:-}" ]; then
    do_add_remote_host
fi

if [ -z "${SUBSTRATE_ADD_PLATFORM:-}" ] \
   && [ -z "${SUBSTRATE_ADD_DEVICES:-}" ] \
   && [ -z "${SUBSTRATE_ADD_REMOTE_HOST:-}" ]; then
    echo "add-platform-device.sh: nothing to do (no --add-* supplied)." >&2
    exit 0
fi
