#!/bin/bash
# Tests for the substrate-identity gate and adoption logic.
# Exercises the six scenarios from briefs/s004-substrate-identity/section.brief.md
# task 4.g. Each scenario stands up an isolated fake repo + a synthetic Docker
# volume, runs the relevant function, and asserts on outcome.
#
# Run:
#   bash infra/scripts/tests/test-substrate-identity.sh
#
# Exits 0 if all scenarios pass, 1 otherwise. Cleans up its volumes whether
# or not it succeeds. Requires a working docker daemon and the
# debian:bookworm-slim image to be pullable (used by the volume-rotation
# helper, same as setup-common.sh and verify.sh).
#
# The harness intentionally does NOT touch the host's real
# claude-state-architect volume. It uses pid-suffixed scratch volumes
# (turtle-core-test-vol-<pid>) so a developer's live substrate is not
# at risk.

set -uo pipefail

repo_src="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_pid=$$
fail_count=0
pass_count=0

test_volume="turtle-core-test-vol-${test_pid}"
test_root_base="/tmp/turtle-core-test-${test_pid}"

if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; NC=''
fi

pass() { printf "${GREEN}PASS${NC}: %s\n" "$*"; pass_count=$((pass_count + 1)); }
fail() { printf "${RED}FAIL${NC}: %s\n" "$*"; fail_count=$((fail_count + 1)); }
note() { printf "${YELLOW}note${NC}: %s\n" "$*"; }
hr()   { printf '%.0s-' {1..70}; printf '\n'; }

cleanup_test() {
    docker ps -a --format '{{.Names}}' \
        | grep -E "^turtle-core-test-arch-${test_pid}$" \
        | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume ls --format '{{.Name}}' \
        | grep -E "^${test_volume}(-rotate-[0-9]+)?$" \
        | xargs -r docker volume rm >/dev/null 2>&1 || true
    rm -rf "${test_root_base}"
}
trap cleanup_test EXIT

# UUID source. Prefer the helper's substrate_id_generate (matches what
# setup actually uses); fall back to /proc/sys/kernel/random/uuid for
# environments without uuidgen. We deliberately don't depend on uuidgen
# being installed on the developer's host.
gen_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        echo "test-harness: cannot generate UUID — neither uuidgen nor /proc UUID source available." >&2
        exit 2
    fi
}

# Build an isolated fake repo tree under /tmp with the helper scripts
# copied in. With 'with-keys', additionally populate id_ed25519 files
# (real ones, via ssh-keygen) for adoption tests. Returns the absolute
# tree path on stdout.
make_test_tree() {
    local mode="${1:-bare}"
    local tree="${test_root_base}/$(date +%s%N)"
    mkdir -p "${tree}/infra/keys"/{architect,planner,coder,auditor,human}
    mkdir -p "${tree}/infra/scripts"
    cp "${repo_src}/infra/scripts/substrate-identity.sh" "${tree}/infra/scripts/"
    cp "${repo_src}/infra/scripts/generate-keys.sh"     "${tree}/infra/scripts/"
    if [ "${mode}" = "with-keys" ]; then
        local role
        for role in architect planner coder auditor; do
            ssh-keygen -t ed25519 -N '' -C "${role}@test-substrate" \
                -f "${tree}/infra/keys/${role}/id_ed25519" -q \
                >/dev/null 2>&1
        done
    fi
    printf '%s\n' "${tree}"
}

# Run a named function inside an isolated subshell with the helper sourced
# and overrides pointing at our test volume / sentinel path. Prints
# 'EXIT=<rc> FRESH=<v> ID=<v>' as the last line of stdout iff the function
# returns normally; if the function exits (via _die), the subshell exits
# and that line is absent (which the asserts use as a "failed loudly" signal).
run_in_isolated() {
    local tree="$1"; shift
    (
        set +e
        cd "${tree}"
        export repo_root="${tree}"
        export SUBSTRATE_ID_VOLUME="${test_volume}"
        export SUBSTRATE_ID_FILE="${tree}/.substrate-id"
        # Stub 'compose stop' / 'compose rm' so substrate_id_adopt's
        # architect-shutdown sequence does not fight a real compose project.
        # If TEST_ARCH_CONTAINER is set, redirect those calls to the named
        # standalone container so the stop+rm sequence is actually exercised
        # against a real container holding the test volume. Other docker
        # calls are passed through.
        docker() {
            if [ "${1:-}" = "compose" ] && [ "${2:-}" = "stop" ]; then
                if [ -n "${TEST_ARCH_CONTAINER:-}" ]; then
                    command docker stop "${TEST_ARCH_CONTAINER}" >/dev/null 2>&1 || true
                fi
                return 0
            fi
            if [ "${1:-}" = "compose" ] && [ "${2:-}" = "rm" ]; then
                if [ -n "${TEST_ARCH_CONTAINER:-}" ]; then
                    command docker rm -f "${TEST_ARCH_CONTAINER}" >/dev/null 2>&1 || true
                fi
                return 0
            fi
            command docker "$@"
        }
        # shellcheck source=../substrate-identity.sh
        . "${tree}/infra/scripts/substrate-identity.sh"
        "$@"
        rc=$?
        echo "EXIT=${rc} FRESH=${SUBSTRATE_ID_FRESH_INSTALL:-unset} ID=${SUBSTRATE_ID:-unset}"
    )
}

# Ensure no leftover volume from a previous run.
docker volume rm "${test_volume}" >/dev/null 2>&1 || true
mkdir -p "${test_root_base}"

# ---------------------------------------------------------------------------
# Scenario 1: fresh install (no disk, no volume).
# ---------------------------------------------------------------------------
hr; echo "Scenario 1: fresh install"
tree=$(make_test_tree)
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "Fresh install. Generated substrate identity:" && \
   echo "${out}" | grep -q "EXIT=0" && \
   echo "${out}" | grep -q "FRESH=1" && \
   [ -f "${tree}/.substrate-id" ]; then
    pass "fresh install: gate generated UUID, wrote sentinel, signalled FRESH=1"
else
    fail "fresh install: expected gate to write sentinel and signal FRESH=1"
fi

# ---------------------------------------------------------------------------
# Scenario 2: matching id (existing substrate, ordinary re-setup).
# ---------------------------------------------------------------------------
hr; echo "Scenario 2: matching id"
tree=$(make_test_tree)
known_id=$(gen_uuid)
docker volume create --label "app.turtle-core.substrate-id=${known_id}" "${test_volume}" >/dev/null
echo "${known_id}" > "${tree}/.substrate-id"
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "Confirmed: ${known_id}" && \
   echo "${out}" | grep -q "EXIT=0" && \
   echo "${out}" | grep -q "FRESH=0" && \
   echo "${out}" | grep -q "ID=${known_id}"; then
    pass "matching id: gate confirmed identity quietly"
else
    fail "matching id: gate did not confirm and proceed"
fi
docker volume rm "${test_volume}" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 3: mismatched ids.
# ---------------------------------------------------------------------------
hr; echo "Scenario 3: mismatched ids"
tree=$(make_test_tree)
disk_id=$(gen_uuid)
vol_id=$(gen_uuid)
docker volume create --label "app.turtle-core.substrate-id=${vol_id}" "${test_volume}" >/dev/null
echo "${disk_id}" > "${tree}/.substrate-id"
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "substrate identity mismatch" && \
   echo "${out}" | grep -q "${disk_id}" && \
   echo "${out}" | grep -q "${vol_id}" && \
   echo "${out}" | grep -q "docker volume inspect" && \
   ! echo "${out}" | grep -q "EXIT=0"; then
    pass "mismatched ids: gate failed loudly, named both UUIDs"
else
    fail "mismatched ids: expected loud failure with both UUIDs and diagnostic"
fi
docker volume rm "${test_volume}" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 4: disk only (sentinel present, volume absent).
# ---------------------------------------------------------------------------
hr; echo "Scenario 4: disk only"
tree=$(make_test_tree)
disk_id=$(gen_uuid)
echo "${disk_id}" > "${tree}/.substrate-id"
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "${disk_id}" && \
   echo "${out}" | grep -q "does not exist" && \
   echo "${out}" | grep -qE 'rm \.substrate-id|--adopt-existing-substrate|backup' && \
   ! echo "${out}" | grep -q "EXIT=0"; then
    pass "disk only: gate failed loudly with recovery options"
else
    fail "disk only: expected loud failure naming the disk UUID"
fi

# ---------------------------------------------------------------------------
# Scenario 5a: volume only, labelled.
# ---------------------------------------------------------------------------
hr; echo "Scenario 5a: volume only, labelled"
tree=$(make_test_tree)
vol_id=$(gen_uuid)
docker volume create --label "app.turtle-core.substrate-id=${vol_id}" "${test_volume}" >/dev/null
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "tree has no .substrate-id" && \
   echo "${out}" | grep -q "adopt-existing-substrate" && \
   echo "${out}" | grep -q "docker volume inspect" && \
   ! echo "${out}" | grep -q "EXIT=0"; then
    pass "volume only (labelled): gate failed loudly, suggested adoption"
else
    fail "volume only (labelled): expected gate to suggest adoption"
fi
docker volume rm "${test_volume}" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 5b: volume only, unlabelled.
# ---------------------------------------------------------------------------
hr; echo "Scenario 5b: volume only, unlabelled"
tree=$(make_test_tree)
docker volume create "${test_volume}" >/dev/null
out=$(run_in_isolated "${tree}" substrate_id_gate 2>&1)
echo "${out}"
if echo "${out}" | grep -q "tree has no .substrate-id" && \
   echo "${out}" | grep -q "adopt-existing-substrate" && \
   ! echo "${out}" | grep -q "EXIT=0"; then
    pass "volume only (unlabelled): gate failed loudly, suggested adoption"
else
    fail "volume only (unlabelled): expected gate to suggest adoption"
fi
docker volume rm "${test_volume}" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 6: adoption (labelless volume + content → labelled volume + content + sentinel).
# ---------------------------------------------------------------------------
hr; echo "Scenario 6: adoption"
tree=$(make_test_tree with-keys)
docker volume create "${test_volume}" >/dev/null
docker run --rm -v "${test_volume}:/dst" debian:bookworm-slim \
    sh -c 'echo content >/dst/marker && mkdir -p /dst/sub && echo nested >/dst/sub/nested && chown -R 1000:1000 /dst' \
    >/dev/null
out=$(run_in_isolated "${tree}" substrate_id_adopt 2>&1)
echo "${out}"
new_id=$(cat "${tree}/.substrate-id" 2>/dev/null || echo "")
labels=$(docker volume inspect "${test_volume}" --format '{{json .Labels}}' 2>/dev/null || echo "")
content_marker=$(docker run --rm -v "${test_volume}:/src:ro" debian:bookworm-slim cat /src/marker 2>/dev/null || echo "")
content_nested=$(docker run --rm -v "${test_volume}:/src:ro" debian:bookworm-slim cat /src/sub/nested 2>/dev/null || echo "")

if echo "${out}" | grep -q "Adoption complete." && \
   echo "${out}" | grep -q "EXIT=0" && \
   [ -n "${new_id}" ] && \
   echo "${labels}" | grep -q "${new_id}" && \
   [ "${content_marker}" = "content" ] && \
   [ "${content_nested}" = "nested" ]; then
    pass "adoption: contents preserved (root + nested), label applied, sentinel written"
else
    fail "adoption: expected contents preserved + label + sentinel"
    echo "  new_id='${new_id}'"
    echo "  labels='${labels}'"
    echo "  marker='${content_marker}'"
    echo "  nested='${content_nested}'"
fi
docker volume rm "${test_volume}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Scenario 7 (bonus): adoption refuses if .substrate-id already exists.
# ---------------------------------------------------------------------------
hr; echo "Scenario 7: adoption refuses pre-existing sentinel"
tree=$(make_test_tree with-keys)
echo "00000000-0000-4000-8000-000000000000" > "${tree}/.substrate-id"
docker volume create "${test_volume}" >/dev/null
out=$(run_in_isolated "${tree}" substrate_id_adopt 2>&1)
echo "${out}"
if echo "${out}" | grep -q "already exists" && \
   echo "${out}" | grep -q "Adoption mints a NEW identity" && \
   ! echo "${out}" | grep -q "EXIT=0"; then
    pass "adoption: refused because .substrate-id already exists"
else
    fail "adoption: expected refusal on pre-existing sentinel"
fi
docker volume rm "${test_volume}" >/dev/null

# ---------------------------------------------------------------------------
# Scenario 8 (regression — adopt-fix): adoption succeeds when a stopped-but-
# not-removed container still holds a reference to the architect volume.
# Reproduces the bug surfaced during operator-side adoption on hello-turtle:
# 'docker compose stop' halts the container but doesn't remove it, and the
# stopped container's volume reference blocked 'docker volume rm'. The fix
# inserts 'docker compose rm -f architect' between stop and volume rm.
# ---------------------------------------------------------------------------
hr; echo "Scenario 8: adoption with stopped-but-present architect container"
tree=$(make_test_tree with-keys)
docker volume create "${test_volume}" >/dev/null
docker run --rm -v "${test_volume}:/dst" debian:bookworm-slim \
    sh -c 'echo content >/dst/marker && mkdir -p /dst/sub && echo nested >/dst/sub/nested && chown -R 1000:1000 /dst' \
    >/dev/null
test_arch="turtle-core-test-arch-${test_pid}"
docker create --name "${test_arch}" -v "${test_volume}:/data" \
    debian:bookworm-slim sleep infinity >/dev/null
docker start "${test_arch}" >/dev/null
docker stop "${test_arch}" >/dev/null  # mimic 'compose stop architect': stopped, not removed
out=$(TEST_ARCH_CONTAINER="${test_arch}" run_in_isolated "${tree}" substrate_id_adopt 2>&1)
echo "${out}"
new_id=$(cat "${tree}/.substrate-id" 2>/dev/null || echo "")
labels=$(docker volume inspect "${test_volume}" --format '{{json .Labels}}' 2>/dev/null || echo "")
content_marker=$(docker run --rm -v "${test_volume}:/src:ro" debian:bookworm-slim cat /src/marker 2>/dev/null || echo "")
content_nested=$(docker run --rm -v "${test_volume}:/src:ro" debian:bookworm-slim cat /src/sub/nested 2>/dev/null || echo "")
container_gone=0
docker inspect "${test_arch}" >/dev/null 2>&1 || container_gone=1

if echo "${out}" | grep -q "Adoption complete." && \
   echo "${out}" | grep -q "EXIT=0" && \
   [ -n "${new_id}" ] && \
   echo "${labels}" | grep -q "${new_id}" && \
   [ "${content_marker}" = "content" ] && \
   [ "${content_nested}" = "nested" ] && \
   [ "${container_gone}" = "1" ]; then
    pass "adoption (stopped container holding volume): completed, container removed, contents preserved"
else
    fail "adoption (stopped container holding volume): expected completion despite volume reference"
    echo "  new_id='${new_id}'"
    echo "  labels='${labels}'"
    echo "  marker='${content_marker}'"
    echo "  nested='${content_nested}'"
    echo "  container_gone='${container_gone}'"
fi
docker rm -f "${test_arch}" >/dev/null 2>&1 || true
docker volume rm "${test_volume}" >/dev/null 2>&1 || true

hr; printf "Summary: ${GREEN}%d passed${NC}, " "${pass_count}"
if [ "${fail_count}" -gt 0 ]; then
    printf "${RED}%d failed${NC}\n" "${fail_count}"
    exit 1
fi
printf "${GREEN}%d failed${NC}\n" "${fail_count}"
exit 0
