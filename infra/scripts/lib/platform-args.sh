#!/bin/bash
# infra/scripts/lib/platform-args.sh
#
# Argument-parsing helpers for the substrate's --platform / --device
# flag pair (s009 9.b) and the running-substrate --add-platform /
# --add-device pair (s009 9.e).
#
# Sourced from setup-linux.sh and setup-mac.sh BEFORE setup-common.sh
# consumes SUBSTRATE_PLATFORMS / SUBSTRATE_DEVICES. Each entrypoint
# loops over its argv with this file's helpers so the behaviour is
# identical across host platforms.
#
# Functions:
#   platform_args_init                Reset parsing state.
#   platform_args_consume <arg>       Try to consume one argv element.
#                                     Returns 0 if consumed; 1 if not
#                                     (caller should treat as unknown).
#   platform_args_finalize            Validate accumulated state, run
#                                     cross-checks (missing-device
#                                     warnings), export
#                                     SUBSTRATE_PLATFORMS /
#                                     SUBSTRATE_DEVICES /
#                                     SUBSTRATE_ADD_PLATFORM /
#                                     SUBSTRATE_ADD_DEVICES /
#                                     SUBSTRATE_FORCE.
#   platform_args_help_block          Emit the help text for the four
#                                     flags + --force; called from each
#                                     entrypoint's --help handler.

# Resolve repo root one level up from infra/scripts/lib.
_pa_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="${PLATFORM_REPO_ROOT:-$(cd "${_pa_lib_dir}/../../.." && pwd)}"

# shellcheck source=infra/scripts/lib/yaml.sh
. "${_pa_lib_dir}/yaml.sh"
# shellcheck source=infra/scripts/lib/validate-platform.sh
. "${_pa_lib_dir}/validate-platform.sh"

platform_args_init() {
    _pa_platforms=()
    _pa_devices=()
    _pa_add_platform=""
    _pa_add_devices=()
    _pa_force=0
    _pa_platform_supplied=0
    _pa_device_supplied=0
}

# Consume one argument from argv. Recognised forms:
#   --platform=<csv>
#   --device=<csv>
#   --add-platform=<name>
#   --add-device=<csv>
#   --force
# Returns 0 if consumed, 1 if the caller should keep handling.
platform_args_consume() {
    local arg="$1"
    case "${arg}" in
        --platform=*)
            _pa_platform_supplied=1
            local val="${arg#--platform=}"
            local IFS=','
            for p in ${val}; do
                p="${p## }"; p="${p%% }"
                [ -n "${p}" ] && _pa_platforms+=("${p}")
            done
            return 0
            ;;
        --device=*)
            _pa_device_supplied=1
            local val="${arg#--device=}"
            local IFS=','
            for d in ${val}; do
                d="${d## }"; d="${d%% }"
                [ -n "${d}" ] && _pa_devices+=("${d}")
            done
            return 0
            ;;
        --add-platform=*)
            if [ -n "${_pa_add_platform}" ]; then
                echo "platform-args: --add-platform may be supplied at most once per invocation" >&2
                exit 2
            fi
            _pa_add_platform="${arg#--add-platform=}"
            return 0
            ;;
        --add-device=*)
            local val="${arg#--add-device=}"
            local IFS=','
            for d in ${val}; do
                d="${d## }"; d="${d%% }"
                [ -n "${d}" ] && _pa_add_devices+=("${d}")
            done
            return 0
            ;;
        --force)
            _pa_force=1
            return 0
            ;;
    esac
    return 1
}

# Validate accumulated state and export the env vars. Default platform
# is 'default' if none supplied. Devices must exist on the host. For
# every selected platform with runtime.device_required: true and no
# device mapped, emit a warning naming the platform + its device_hint.
# Setup proceeds (per design call 5).
platform_args_finalize() {
    yaml_pull

    # Drop a literal 'default' from the list — it's a no-op layer that
    # we keep accepting for orthogonality (--platform=default,go is
    # equivalent to --platform=go) but don't want appearing twice if
    # the human also mentioned a real platform.
    local cleaned=()
    local seen_default=0
    if [ "${#_pa_platforms[@]}" -gt 0 ]; then
        for p in "${_pa_platforms[@]}"; do
            if [ "${p}" = "default" ]; then
                seen_default=1
                continue
            fi
            cleaned+=("${p}")
        done
    fi

    # If no platforms supplied, fall back to 'default'.
    if [ "${#cleaned[@]}" -eq 0 ]; then
        cleaned=("default")
    fi

    # Validate each platform YAML.
    for p in "${cleaned[@]}"; do
        if ! validate_platform "${p}" 2>&1; then
            echo "[setup] FATAL: platform '${p}' failed schema validation (see message above)." >&2
            exit 1
        fi
    done

    # Validate each device path exists on the host.
    if [ "${#_pa_devices[@]}" -gt 0 ]; then
        for d in "${_pa_devices[@]}"; do
            if [ ! -e "${d}" ]; then
                echo "[setup] FATAL: --device='${d}': path does not exist on host." >&2
                exit 1
            fi
        done
    fi

    # Cross-check: warn if any selected platform requires a device and
    # none has been mapped. Per design call 5 this is a warning, not a
    # failure: humans legitimately want compile-only initially.
    local missing_devices=()
    if [ "${#_pa_devices[@]}" -eq 0 ]; then
        for p in "${cleaned[@]}"; do
            local file="${PLATFORM_REPO_ROOT}/methodology/platforms/${p}.yaml"
            local req hint
            req=$(yaml_eval '.runtime.device_required // false' "${file}")
            if [ "${req}" = "true" ]; then
                hint=$(yaml_eval '.runtime.device_hint // ""' "${file}")
                missing_devices+=("${p}|${hint}")
            fi
        done
    fi

    SUBSTRATE_PLATFORMS=$(IFS=','; printf '%s' "${cleaned[*]}")
    if [ "${#_pa_devices[@]}" -gt 0 ]; then
        SUBSTRATE_DEVICES=$(IFS=','; printf '%s' "${_pa_devices[*]}")
    else
        SUBSTRATE_DEVICES=""
    fi
    SUBSTRATE_ADD_PLATFORM="${_pa_add_platform}"
    if [ "${#_pa_add_devices[@]}" -gt 0 ]; then
        SUBSTRATE_ADD_DEVICES=$(IFS=','; printf '%s' "${_pa_add_devices[*]}")
    else
        SUBSTRATE_ADD_DEVICES=""
    fi
    SUBSTRATE_FORCE="${_pa_force}"
    SUBSTRATE_PLATFORM_SUPPLIED="${_pa_platform_supplied}"
    SUBSTRATE_DEVICE_SUPPLIED="${_pa_device_supplied}"
    if [ "${#missing_devices[@]}" -gt 0 ]; then
        SUBSTRATE_DEVICE_REQUIRED_MISSING=$(IFS=$'\n'; printf '%s' "${missing_devices[*]}")
    else
        SUBSTRATE_DEVICE_REQUIRED_MISSING=""
    fi
    export SUBSTRATE_PLATFORMS SUBSTRATE_DEVICES \
           SUBSTRATE_ADD_PLATFORM SUBSTRATE_ADD_DEVICES \
           SUBSTRATE_FORCE SUBSTRATE_PLATFORM_SUPPLIED \
           SUBSTRATE_DEVICE_SUPPLIED SUBSTRATE_DEVICE_REQUIRED_MISSING

    # First emission of the missing-device warning. setup-common.sh
    # repeats it at the end of setup so it's the last thing the human
    # sees (the brief flagged scrollback as a real risk).
    if [ -n "${SUBSTRATE_DEVICE_REQUIRED_MISSING}" ]; then
        echo
        echo "[setup] WARNING: the following selected platform(s) declare runtime.device_required=true" >&2
        echo "        but no --device= flag was supplied:" >&2
        local IFS=$'\n'
        for entry in ${SUBSTRATE_DEVICE_REQUIRED_MISSING}; do
            local pname="${entry%%|*}"
            local phint="${entry#*|}"
            echo "          - ${pname}: ${phint}" >&2
        done
        echo "        Compile-only workflows still work; HIL test/flash/serial-monitor will not." >&2
        echo "        Add a device with --add-device=<host-path> after setup, or re-run setup" >&2
        echo "        with --device=<host-path>." >&2
        echo
    fi

    # Tell the human (and downstream readers of stdout) what we landed on.
    if [ "${seen_default}" -eq 1 ] && [ "${#cleaned[@]}" -gt 1 ]; then
        echo "[setup] --platform=default folded into other selections." >&2
    fi
    echo "[setup] SUBSTRATE_PLATFORMS=${SUBSTRATE_PLATFORMS}"
    echo "[setup] SUBSTRATE_DEVICES=${SUBSTRATE_DEVICES:-(none)}"
}

platform_args_help_block() {
    cat <<'EOF'
  --platform=<name>[,<name2>,...]
                     Select one or more target platforms at substrate
                     setup time. The renderer composes each platform's
                     install layers into the coder-daemon and auditor
                     images. Repeatable flags are concatenated. Absent
                     or empty implies --platform=default (no extra
                     toolchain). Available platforms live under
                     methodology/platforms/. Polyglot mode is
                     --platform=a,b,...

  --device=<host-path>[,<host-path2>,...]
                     Pass one or more host devices through to the
                     coder-daemon and auditor containers (e.g. an ESP32
                     board on /dev/ttyUSB0). Required only for platforms
                     that declare runtime.device_required=true (currently
                     platformio-esp32). Repeatable; each path must exist
                     at parse time. The setup script renders an override
                     compose file with a 'devices:' entry for each.

  --add-platform=<name>
                     One-shot extension on a running substrate. Refuses
                     by default if any ephemeral container is running OR
                     any section/* branch on origin has unmerged commits;
                     pass --force to override.

  --add-device=<host-path>[,<host-path2>,...]
                     One-shot device-passthrough extension on a running
                     substrate. No image rebuild required (devices are
                     runtime, not build-time). Refuses if any ephemeral
                     container is running, unless --force.

  --force            Skip the --add-platform / --add-device pre-flight
                     checks. Use when you know what you're doing.
EOF
}
