#!/bin/bash
# infra/scripts/compose-image.sh — JIT platform-composition orchestrator
# (s013 / F50).
#
# Composes a dispatched-agent role image with a declared set of
# platforms at commission time. Produces a hash-tagged image and
# caches it across commissions so unchanged declarations reuse the
# image without rebuilding.
#
# Usage:
#   compose-image.sh <role> <comma-platforms>
#
# Roles: coder-daemon, auditor, planner, onboarder.
# Platforms: comma-separated names matching methodology/platforms/<name>.yaml.
#   Empty string, the literal "default", and duplicates are normalised
#   away — the empty platform set produces a stable hash and a "no
#   platforms" image (= the static template build aside from a
#   generated-file header).
#
# Output (stdout): a single line containing the resulting image tag,
#   e.g. "agent-coder-daemon-platforms:a3f9c1e8b2d4". The caller
#   (commission-pair.sh / audit.sh / onboard-project.sh) passes that
#   tag into docker-compose via the per-role image env-var override.
#
# Logging (stderr): progress messages, prefixed "[compose-image]".
#
# Exit codes:
#   0  success — tag emitted on stdout
#   1  bad args, missing/invalid platform YAML, missing build context
#   2  docker build failure
#
# Hash semantics (see methodology/platforms/README.md "Composition
# hash semantics"):
#   - role name
#   - canonical sorted, deduped, default-stripped platform names
#   - sha256 of each selected platform YAML's bytes (registry-entry
#     content hash — picks up edits to a YAML's install/verify/env
#     lists, so cache invalidates automatically on registry change)
#
# Backward compatibility: this script does NOT touch the s009 setup-
# time tag (`agent-<role>:latest`). The JIT tag is a separate
# `agent-<role>-platforms:<hash>` namespace; both coexist in the
# local docker image cache without collision. Operators on pre-F50
# substrates keep working unchanged.

set -euo pipefail

if [ "$#" -ne 2 ]; then
    cat >&2 <<'EOF'
Usage: compose-image.sh <role> <comma-platforms>

  role        coder-daemon | auditor | planner | onboarder
  platforms   comma-separated platform names; '' or 'default' are
              equivalent to the empty set (no platform layers added).

Emits the resulting image tag on stdout.
EOF
    exit 1
fi

ROLE="$1"
PLATFORMS_CSV="$2"

case "${ROLE}" in
    coder-daemon|auditor|planner|onboarder) ;;
    *)
        echo "compose-image: unknown role '${ROLE}' (expected coder-daemon, auditor, planner, or onboarder)" >&2
        exit 1
        ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
log() { printf '[compose-image] %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Canonicalise the platform list. Drop empties, drop 'default' (it's
#    a no-op layer), dedupe, sort. The result is what gets hashed and
#    what gets passed to render-dockerfile.sh.
# ---------------------------------------------------------------------------
canonical_platforms=()
seen=""
IFS=',' read -ra raw_list <<< "${PLATFORMS_CSV}"
for raw in "${raw_list[@]}"; do
    p="${raw## }"; p="${p%% }"
    [ -z "${p}" ] && continue
    [ "${p}" = "default" ] && continue
    case " ${seen} " in
        *" ${p} "*) continue ;;
    esac
    canonical_platforms+=("${p}")
    seen="${seen} ${p}"
done

# Sort. Bash arrays don't sort natively; round-trip via printf+sort.
if [ "${#canonical_platforms[@]}" -gt 0 ]; then
    mapfile -t canonical_platforms < <(printf '%s\n' "${canonical_platforms[@]}" | sort)
fi

# ---------------------------------------------------------------------------
# 2. Validate each platform's YAML exists. Schema validation is the
#    job of validate-platform.sh (s009); compose-image only needs to
#    fail fast on a missing file so the hash can include the bytes.
# ---------------------------------------------------------------------------
for p in "${canonical_platforms[@]:-}"; do
    [ -z "${p}" ] && continue
    yaml="${repo_root}/methodology/platforms/${p}.yaml"
    if [ ! -f "${yaml}" ]; then
        echo "compose-image: platform '${p}' has no YAML at ${yaml}" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 3. Compute the canonical hash. Inputs (newline-separated, then
#    sha256'd):
#       role
#       each canonical platform name (one per line)
#       sha256 of each platform YAML's bytes (one per line, paired with
#         the platform name for readability when debugging hash drift)
#    The output is the 12-char prefix used as the image tag suffix.
# ---------------------------------------------------------------------------
hash_input() {
    printf 'role=%s\n' "${ROLE}"
    for p in "${canonical_platforms[@]:-}"; do
        [ -z "${p}" ] && continue
        printf 'platform=%s\n' "${p}"
    done
    for p in "${canonical_platforms[@]:-}"; do
        [ -z "${p}" ] && continue
        yaml="${repo_root}/methodology/platforms/${p}.yaml"
        # sha256sum is in coreutils on Linux and ships on macOS via
        # `brew install coreutils` (gsha256sum) or is reachable through
        # `shasum -a 256`. Prefer sha256sum, fall back to shasum.
        if command -v sha256sum >/dev/null 2>&1; then
            entry_hash=$(sha256sum "${yaml}" | awk '{print $1}')
        else
            entry_hash=$(shasum -a 256 "${yaml}" | awk '{print $1}')
        fi
        printf 'yaml=%s sha256=%s\n' "${p}" "${entry_hash}"
    done
}

if command -v sha256sum >/dev/null 2>&1; then
    full_hash=$(hash_input | sha256sum | awk '{print $1}')
else
    full_hash=$(hash_input | shasum -a 256 | awk '{print $1}')
fi
short_hash="${full_hash:0:12}"

image_tag="agent-${ROLE}-platforms:${short_hash}"

# ---------------------------------------------------------------------------
# 4. Cache check. `docker image inspect` is fast and exits 0 iff the
#    tag exists locally. We don't push or pull; the cache is local to
#    this docker daemon.
# ---------------------------------------------------------------------------
if docker image inspect "${image_tag}" >/dev/null 2>&1; then
    log "cache hit: ${image_tag} (role=${ROLE}, platforms=[${canonical_platforms[*]:-}])"
    printf '%s\n' "${image_tag}"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Cache miss — render and build.
#
#    The build context is the role's infra/<role>/ dir (same as the
#    s009 setup-time docker-compose build). The Dockerfile is rendered
#    to a tempfile that lives next to the build context so docker
#    build can find the context's COPY sources. We use `--file -` (read
#    Dockerfile from stdin) to avoid a tempfile entirely, which is
#    clean for docker build's contract.
# ---------------------------------------------------------------------------
context="${repo_root}/infra/${ROLE}"
if [ ! -d "${context}" ]; then
    echo "compose-image: build context not found at ${context}" >&2
    exit 1
fi

# Sanity-check agent-base exists. compose-image doesn't build it
# (that's setup's job); error helpfully if it's missing.
if ! docker image inspect agent-base:latest >/dev/null 2>&1; then
    cat >&2 <<'EOF'
compose-image: agent-base:latest is missing. JIT composition layers
on top of the substrate base image, which is built at setup time.

Run ./setup-linux.sh (or setup-mac.sh) on this clone first, then
re-try the commission.
EOF
    exit 1
fi

# Render to a tempfile rather than piping into docker build stdin, so
# a render failure surfaces cleanly without being entangled with the
# docker build's exit code.
dockerfile_tmp=$(mktemp)
trap 'rm -f "${dockerfile_tmp}"' EXIT

# render-dockerfile.sh's --stdout mode emits the rendered content
# without writing the static infra/<role>/Dockerfile.generated path
# (which is reserved for the s009 setup-time entry point — don't
# clobber it during JIT).
platforms_for_renderer=$(IFS=','; printf '%s' "${canonical_platforms[*]:-default}")
[ -z "${platforms_for_renderer}" ] && platforms_for_renderer="default"

log "rendering Dockerfile for role=${ROLE}, platforms=${platforms_for_renderer}"
if ! "${repo_root}/infra/scripts/render-dockerfile.sh" --stdout "${ROLE}" "${platforms_for_renderer}" > "${dockerfile_tmp}"; then
    echo "compose-image: render-dockerfile.sh failed for role=${ROLE} platforms=${platforms_for_renderer}" >&2
    exit 1
fi

log "building ${image_tag} (cache miss; this may take a minute on first build)"
if ! docker build \
        -t "${image_tag}" \
        -f "${dockerfile_tmp}" \
        "${context}" \
        >&2; then
    echo "compose-image: docker build failed for ${image_tag}" >&2
    exit 2
fi

log "built ${image_tag}"
printf '%s\n' "${image_tag}"
