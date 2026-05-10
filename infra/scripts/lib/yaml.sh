#!/bin/bash
# infra/scripts/lib/yaml.sh
#
# Thin wrappers around `mikefarah/yq:4` (the Go yq, not the Python one)
# run in a one-shot Docker container. Source this from any setup-time
# script that needs to read a platform YAML.
#
# Why a Docker wrapper rather than a host binary:
#   - The substrate already requires Docker (everything else hangs off it).
#   - mikefarah/yq:4 is a single static binary in a tiny (~15MB) image,
#     so the per-call overhead is just docker-run startup (~150ms).
#   - We avoid imposing an extra host prereq on humans setting up the
#     substrate (the python-yq from Debian apt is a different program
#     with incompatible syntax — a footgun we sidestep entirely by
#     pinning the image tag).
#
# Functions:
#   yaml_pull           Pre-pull the yq image; idempotent. Call once early
#                       in setup so the first real query is not slow.
#   yaml_to_json <file> Convert a YAML file to JSON on stdout. The whole
#                       document is emitted; downstream code parses with
#                       python3 (json stdlib is on every host).
#   yaml_eval <expr> <file>
#                       Evaluate an arbitrary yq expression against <file>
#                       and print the result. For simple flat queries.

# Pinned tag — bump deliberately. Pinning protects against yq behaviour
# changes (e.g. the v3 → v4 syntax break) silently breaking setup.
YAML_YQ_IMAGE="mikefarah/yq:4"

yaml_pull() {
    if ! docker image inspect "${YAML_YQ_IMAGE}" >/dev/null 2>&1; then
        docker pull "${YAML_YQ_IMAGE}" >/dev/null
    fi
}

# Mount the file's directory and reference the file by basename inside
# the container so paths with spaces or symlinks work uniformly.
_yaml_run() {
    local file="$1"; shift
    local abs dir base
    abs=$(cd "$(dirname "${file}")" && pwd)/$(basename "${file}")
    dir=$(dirname "${abs}")
    base=$(basename "${abs}")
    docker run --rm \
        -v "${dir}:/yaml:ro" \
        -w /yaml \
        "${YAML_YQ_IMAGE}" "$@" "${base}"
}

yaml_to_json() {
    local file="$1"
    _yaml_run "${file}" -o=json '.'
}

yaml_eval() {
    local expr="$1"
    local file="$2"
    _yaml_run "${file}" eval "${expr}"
}
