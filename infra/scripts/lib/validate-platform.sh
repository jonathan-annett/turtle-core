#!/bin/bash
# infra/scripts/lib/validate-platform.sh
#
# Validates a platform YAML against the schema documented in
# methodology/platforms/README.md. Sourced (or executed) by setup-common.sh
# before the renderer is invoked. A validation failure aborts setup with a
# diagnostic identifying the file and the failing field.
#
# Usage:
#   validate_platform <name>
#       Validates methodology/platforms/<name>.yaml. Returns 0 on success,
#       non-zero with an error message on failure.
#
#   validate_platform_file <path>
#       Same, but takes an explicit file path (used by tests).
#
# Implementation: yaml_to_json (mikefarah/yq:4) → python3 -c '...' which
# reads the JSON and applies the schema rules. This avoids depending on
# PyYAML on the host (json is in stdlib).

# Resolve repo root one level up from this lib directory; allow override
# for tests that source the file from elsewhere.
_validate_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_REPO_ROOT="${PLATFORM_REPO_ROOT:-$(cd "${_validate_lib_dir}/../../.." && pwd)}"

# shellcheck source=infra/scripts/lib/yaml.sh
. "${_validate_lib_dir}/yaml.sh"

validate_platform() {
    local name="$1"
    local file="${PLATFORM_REPO_ROOT}/methodology/platforms/${name}.yaml"
    if [ ! -f "${file}" ]; then
        echo "[validate-platform] FATAL: platform '${name}' has no YAML at ${file}" >&2
        return 1
    fi
    validate_platform_file "${file}"
}

validate_platform_file() {
    local file="$1"
    local expected_name
    expected_name=$(basename "${file}" .yaml)

    local json
    if ! json=$(yaml_to_json "${file}" 2>/dev/null); then
        echo "[validate-platform] FATAL: ${file}: not parseable as YAML" >&2
        return 1
    fi

    EXPECTED_NAME="${expected_name}" \
    PLATFORM_FILE="${file}" \
    PLATFORM_JSON="${json}" \
    python3 - <<'PY'
import json, os, sys

file = os.environ["PLATFORM_FILE"]
expected_name = os.environ["EXPECTED_NAME"]
data = json.loads(os.environ["PLATFORM_JSON"])

errors = []

def err(msg):
    errors.append(f"{file}: {msg}")

if not isinstance(data, dict):
    err("top-level must be a mapping")
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

# name (required, must match filename)
name = data.get("name")
if not isinstance(name, str) or not name:
    err("'name' is required and must be a non-empty string")
elif name != expected_name:
    err(f"'name' is '{name}' but filename implies '{expected_name}'")

# description (required)
desc = data.get("description")
if not isinstance(desc, str) or not desc:
    err("'description' is required and must be a non-empty string")

# roles (required, map; may be empty)
roles = data.get("roles")
if roles is None or not isinstance(roles, dict):
    err("'roles' is required and must be a mapping (may be empty: {})")
    roles = {}

valid_role_names = {"coder-daemon", "auditor", "planner", "onboarder"}
for role_name, role in roles.items():
    if role_name not in valid_role_names:
        err(f"roles.{role_name}: unknown role; must be one of {sorted(valid_role_names)}")
        continue
    if role is None:
        # yq emits null for an empty mapping; treat as no-op
        continue
    if not isinstance(role, dict):
        err(f"roles.{role_name}: must be a mapping (or omitted)")
        continue
    for list_field in ("apt", "install", "verify"):
        if list_field in role:
            v = role[list_field]
            if not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
                err(f"roles.{role_name}.{list_field}: must be a non-empty list of strings")
        # nothing more to check; missing is fine
    if "env" in role:
        env = role["env"]
        if not isinstance(env, dict):
            err(f"roles.{role_name}.env: must be a mapping of name → value")
        else:
            for k, val in env.items():
                if not isinstance(k, str) or not k:
                    err(f"roles.{role_name}.env: key '{k}' must be a non-empty string")
                if not isinstance(val, (str, int, float, bool)):
                    err(f"roles.{role_name}.env.{k}: value must be a scalar (string/number/bool)")

# runtime (optional)
if "runtime" in data:
    rt = data["runtime"]
    if not isinstance(rt, dict):
        err("'runtime' must be a mapping")
    else:
        if "device_required" in rt and not isinstance(rt["device_required"], bool):
            err("runtime.device_required must be a bool")
        if "device_hint" in rt and not (isinstance(rt["device_hint"], str) and rt["device_hint"]):
            err("runtime.device_hint must be a non-empty string")
        if "groups" in rt:
            g = rt["groups"]
            if not isinstance(g, list) or not all(isinstance(x, str) and x for x in g):
                err("runtime.groups must be a list of strings")

# defaults (optional)
if "defaults" in data:
    df = data["defaults"]
    if not isinstance(df, dict):
        err("'defaults' must be a mapping")
    else:
        for s in ("test_runner", "build_command"):
            if s in df and not isinstance(df[s], str):
                err(f"defaults.{s} must be a string (may be empty)")
        if "allowed_tools" in df:
            t = df["allowed_tools"]
            if not isinstance(t, list) or not all(isinstance(x, str) and x for x in t):
                err("defaults.allowed_tools must be a list of strings")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

# Direct-execution mode for ad-hoc validation:
#     bash infra/scripts/lib/validate-platform.sh <name-or-path>
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$#" -ne 1 ]; then
        echo "Usage: $0 <platform-name-or-yaml-path>" >&2
        exit 2
    fi
    target="$1"
    yaml_pull
    if [ -f "${target}" ]; then
        validate_platform_file "${target}"
    else
        validate_platform "${target}"
    fi
fi
