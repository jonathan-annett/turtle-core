#!/bin/bash
# test-substrate-end-to-end.sh — substrate-level end-to-end test for s007.
#
# This is the test that should have caught the three issues s007 closes:
#   1. .claude.json was not propagated by the volume model — planner had no
#      ~/.claude.json on first start, claude-code prompted for OAuth login.
#   2. The daemon's source-IP guard closed-failed because the planner had
#      no stable hostname/alias on agent-net — every commission was 503'd.
#   3. The planner's working tree had no CLAUDE.md, so the planner needed
#      a human seed prompt to load its methodology guide.
#
# Real-claude-code execution by the coder is NOT exercised — that needs
# Anthropic credentials and is exercised when the architect dispatches
# actual section work after s007 merges. Here, the daemon spawns a STUB
# claude binary (injected into the daemon container's PATH) that writes
# the expected report and exits. Substrate verification, not coder
# verification.
#
# The test is fully isolated — every resource it creates is pid-suffixed
# and torn down via trap. The host's real substrate (claude-state-architect,
# claude-state-shared, main.git, agent-net) is not touched.
#
# Required: agent-{base,architect,planner,coder-daemon,git-server} images
# already built (`./setup-linux.sh` or `./setup-mac.sh`).
#
# Run:
#   bash infra/scripts/tests/test-substrate-end-to-end.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_pid=$$
project="turtle-core-test-s007e2e-${test_pid}"
network="${project}-net"
vol_arch="${project}-claude-state-architect"
vol_shared="${project}-claude-state-shared"
vol_main_bare="${project}-main-bare"
vol_auditor_bare="${project}-auditor-bare"
vol_arch_workspace="${project}-architect-workspace"
vol_arch_auditor_clone="${project}-architect-auditor-clone"
vol_coder_state="${project}-coder-state"
work_dir="/tmp/${project}"
keys_dir="${work_dir}/keys"
compose_file="${work_dir}/docker-compose.yml"
env_file="${work_dir}/env"

COMMISSION_PORT=$(awk -v min=30000 -v max=39999 'BEGIN{srand();print int(min+rand()*(max-min+1))}')
COMMISSION_TOKEN=$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-43)

if [ -t 1 ]; then
    GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; NC=''
fi

pass_count=0; fail_count=0
pass() { printf "${GREEN}PASS${NC}: %s\n" "$*"; pass_count=$((pass_count+1)); }
fail() { printf "${RED}FAIL${NC}: %s\n" "$*"; fail_count=$((fail_count+1)); }
note() { printf "${YELLOW}note${NC}: %s\n" "$*"; }
hr()   { printf '%.0s-' $(seq 1 70); printf '\n'; }

cleanup_test() {
    local rc=$?
    note "tearing down ${project}..."
    if [ -f "${compose_file}" ] && [ -f "${env_file}" ]; then
        docker compose -p "${project}" -f "${compose_file}" --env-file "${env_file}" \
            --profile ephemeral down --remove-orphans >/dev/null 2>&1 || true
    fi
    docker volume rm \
        "${vol_arch}" "${vol_shared}" \
        "${vol_main_bare}" "${vol_auditor_bare}" \
        "${vol_arch_workspace}" "${vol_arch_auditor_clone}" \
        "${vol_coder_state}" \
        >/dev/null 2>&1 || true
    docker network rm "${network}" >/dev/null 2>&1 || true
    rm -rf "${work_dir}" 2>/dev/null || true
    exit "${rc}"
}
trap cleanup_test EXIT INT TERM

ce() {
    docker compose -p "${project}" -f "${compose_file}" --env-file "${env_file}" "$@"
}

# ---------------------------------------------------------------------------
# Phase 0 — prereqs
# ---------------------------------------------------------------------------
hr; echo "Phase 0: prereqs"

req_imgs=(agent-base agent-architect agent-planner agent-coder-daemon agent-git-server)
missing=0
for img in "${req_imgs[@]}"; do
    if ! docker image inspect "${img}:latest" >/dev/null 2>&1; then
        fail "image '${img}:latest' is missing — run setup-linux.sh / setup-mac.sh first"
        missing=1
    fi
done
[ "${missing}" -eq 0 ] && pass "all required images present"
if [ "${missing}" -ne 0 ]; then
    note "stopping: cannot exercise the substrate without the role images"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1 — scaffold scratch substrate
# ---------------------------------------------------------------------------
hr; echo "Phase 1: scaffold scratch substrate"

mkdir -p "${keys_dir}"/{architect,planner,coder,auditor,human}
chmod 700 "${keys_dir}"
chmod 700 "${keys_dir}"/*
for role in architect planner coder auditor human; do
    ssh-keygen -t ed25519 -N '' -C "${role}@${project}" \
        -f "${keys_dir}/${role}/id_ed25519" -q >/dev/null 2>&1
    chmod 600 "${keys_dir}/${role}/id_ed25519"
done
pass "generated scratch ssh keys"

docker network create "${network}" >/dev/null
pass "created scratch network '${network}'"

for vol in "${vol_arch}" "${vol_shared}" "${vol_main_bare}" "${vol_auditor_bare}" \
           "${vol_arch_workspace}" "${vol_arch_auditor_clone}" "${vol_coder_state}"; do
    docker volume create "${vol}" >/dev/null
done
docker run --rm \
    -v "${vol_arch}:/a" -v "${vol_shared}:/s" \
    debian:bookworm-slim \
    sh -c 'chown 1000:1000 /a /s && chmod 0700 /a /s' >/dev/null
pass "created scratch volumes (mount-roots normalised)"

cat > "${env_file}" <<ENV_EOF
COMMISSION_PORT=${COMMISSION_PORT}
COMMISSION_TOKEN=${COMMISSION_TOKEN}
ENV_EOF

cat > "${compose_file}" <<COMPOSE_EOF
# Generated for substrate-end-to-end test (pid ${test_pid}).
services:
  git-server:
    image: agent-git-server:latest
    container_name: ${project}-git-server
    hostname: git-server
    volumes:
      - ${vol_main_bare}:/srv/git/main.git
      - ${vol_auditor_bare}:/srv/git/auditor.git
      - ${keys_dir}:/srv/keys:ro
    networks:
      agent-net:
        aliases: [git-server]

  architect:
    image: agent-architect:latest
    container_name: ${project}-architect
    depends_on: [git-server]
    volumes:
      - ${vol_arch_workspace}:/work
      - ${vol_arch_auditor_clone}:/auditor
      - ${vol_arch}:/home/agent/.claude
      - ${repo_root}/methodology:/methodology:ro
      - ${keys_dir}/architect:/home/agent/.ssh:ro
    networks: [agent-net]
    stdin_open: true
    tty: true

  planner:
    image: agent-planner:latest
    profiles: ["ephemeral"]
    depends_on: [coder-daemon]
    environment:
      COMMISSION_HOST: coder-daemon
      COMMISSION_PORT: \${COMMISSION_PORT:-}
      COMMISSION_TOKEN: \${COMMISSION_TOKEN:-}
    volumes:
      - ${vol_shared}:/home/agent/.claude
      - ${repo_root}/methodology:/methodology:ro
      - ${keys_dir}/planner:/home/agent/.ssh:ro
    networks: [agent-net]
    stdin_open: true
    tty: true

  coder-daemon:
    image: agent-coder-daemon:latest
    container_name: ${project}-daemon
    profiles: ["ephemeral"]
    environment:
      COMMISSION_PORT: \${COMMISSION_PORT:-}
      COMMISSION_TOKEN: \${COMMISSION_TOKEN:-}
    volumes:
      - ${vol_coder_state}:/data
      - ${vol_shared}:/home/agent/.claude
      - ${repo_root}/methodology:/methodology:ro
      - ${keys_dir}/coder:/home/agent/.ssh:ro
    networks: [agent-net]

volumes:
  ${vol_main_bare}:
    external: true
  ${vol_auditor_bare}:
    external: true
  ${vol_arch_workspace}:
    external: true
  ${vol_arch_auditor_clone}:
    external: true
  ${vol_arch}:
    external: true
  ${vol_shared}:
    external: true
  ${vol_coder_state}:
    external: true

networks:
  agent-net:
    external: true
    name: ${network}
COMPOSE_EOF

pass "wrote scratch compose + env"

# ---------------------------------------------------------------------------
# Phase 2 — bring up git-server, init bare repos
# ---------------------------------------------------------------------------
hr; echo "Phase 2: scratch git-server + bare repos"

ce up -d git-server >/dev/null
for _ in $(seq 1 30); do
    if ce exec -T git-server pgrep -x sshd >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
if ce exec -T git-server /srv/init-repos.sh >/dev/null 2>&1; then
    pass "git-server up, main.git + auditor.git initialised"
else
    fail "git-server failed to init bare repos"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 3 — bring up architect; verify entrypoint outcomes
# ---------------------------------------------------------------------------
hr; echo "Phase 3: architect entrypoint (7.a + 7.c symlinks)"

ce up -d architect >/dev/null
for _ in $(seq 1 30); do
    if ce exec -T -u agent architect test -e /home/agent/.claude.json 2>/dev/null; then
        break
    fi
    sleep 1
done

# 7.a: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json
if ce exec -T -u agent architect test -L /home/agent/.claude.json; then
    target=$(ce exec -T -u agent architect readlink /home/agent/.claude.json | tr -d '\r')
    if [ "${target}" = "/home/agent/.claude/.claude.json" ]; then
        pass "architect: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json"
    else
        fail "architect: ~/.claude.json symlink target is wrong (got '${target}')"
    fi
else
    fail "architect: ~/.claude.json is not a symlink"
fi

# 7.c: /work/CLAUDE.md is a symlink → /methodology/architect-guide.md
if ce exec -T -u agent architect test -L /work/CLAUDE.md; then
    target=$(ce exec -T -u agent architect readlink /work/CLAUDE.md | tr -d '\r')
    if [ "${target}" = "/methodology/architect-guide.md" ]; then
        pass "architect: /work/CLAUDE.md is a symlink → /methodology/architect-guide.md"
    else
        fail "architect: /work/CLAUDE.md target is wrong (got '${target}')"
    fi
else
    fail "architect: /work/CLAUDE.md is not a symlink"
fi

if ce exec -T -u agent architect grep -qxF 'CLAUDE.md' /work/.git/info/exclude; then
    pass "architect: CLAUDE.md is in /work/.git/info/exclude"
else
    fail "architect: CLAUDE.md missing from /work/.git/info/exclude"
fi

# 7.a migration: replace the symlink with a regular file, restart, verify
# the entrypoint migrates the file into the volume and recreates the symlink.
ce exec -T -u agent architect bash -c '
    rm -f /home/agent/.claude.json
    printf "%s" "{\"migration\":\"sentinel-${RANDOM}\"}" > /home/agent/.claude.json
'
ce stop architect >/dev/null 2>&1
ce start architect >/dev/null 2>&1
for _ in $(seq 1 30); do
    if ce exec -T -u agent architect test -L /home/agent/.claude.json 2>/dev/null; then
        break
    fi
    sleep 1
done
if ce exec -T -u agent architect test -L /home/agent/.claude.json && \
   ce exec -T -u agent architect grep -q '"migration":"sentinel-' /home/agent/.claude/.claude.json; then
    pass "architect: regular ~/.claude.json migrated into volume on restart, symlink restored"
else
    fail "architect: migration on restart did not produce expected outcome"
fi

# ---------------------------------------------------------------------------
# Phase 4 — seed scratch main.git with a section + task brief
# ---------------------------------------------------------------------------
hr; echo "Phase 4: seed main.git with a synthetic section/task brief"

# The architect's git-server hook restricts pushes to briefs/** etc., which
# fits exactly what we need to seed (briefs/test-section/*.brief.md).
seed_remote='git@git-server:/srv/git/main.git'
ce exec -T -u agent architect bash -c '
    set -e
    cd /work
    mkdir -p briefs/test-section
    cat > briefs/test-section/section.brief.md <<BRIEF
# Test section brief — substrate-end-to-end synthetic

This brief drives the synthetic-coder commission in test-substrate-end-
to-end.sh. The daemon spawns a stub claude binary that writes the
expected report and exits.

## Tasks
- t001-stub
BRIEF
    cat > briefs/test-section/t001-stub.brief.md <<BRIEF
# Stub task brief — t001

Substrate-end-to-end test fixture. The coder is a stub.

- **Touch surface.** N/A
- **Required tool surface.**
  \`\`\`yaml
  - Read
  - Edit
  \`\`\`
BRIEF
    git add briefs
    git -c user.email=architect@substrate.local -c user.name=architect \
        commit -q -m "test fixture: section + task brief for substrate e2e"
    git push -q origin main
'
if [ $? -eq 0 ]; then
    pass "seeded section.brief.md + t001-stub.brief.md on origin/main"
else
    fail "seed push failed"
    exit 1
fi

# Also create the section branch from main, since the daemon's runCoder
# fetches origin/<section_branch> and checks it out before spawning the
# coder. Real planners create section branches; for the test the architect
# can do it (the hook permits architect → main only, but section branches
# are pushed by planners; we use the human key for the section-branch
# push since it's unrestricted).
docker run --rm \
    -v "${keys_dir}/human:/k:ro" \
    --network "${network}" \
    debian:bookworm-slim \
    sh -c '
        apt-get update -qq >/dev/null 2>&1 && \
            apt-get install -qq -y --no-install-recommends git openssh-client >/dev/null 2>&1
        export GIT_SSH_COMMAND="ssh -i /k/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
        tmp=$(mktemp -d)
        cd "$tmp"
        git -c user.email=h -c user.name=h clone -q git@git-server:/srv/git/main.git .
        git checkout -q -b section/test-section
        git push -q origin section/test-section
    ' >/dev/null 2>&1
if [ $? -eq 0 ]; then
    pass "created section/test-section on origin"
else
    fail "section-branch push failed"
fi

# ---------------------------------------------------------------------------
# Phase 5 — bring up daemon, inject stub claude, verify .claude.json
#           propagated into shared volume by mimicking verify.sh's helper
# ---------------------------------------------------------------------------
hr; echo "Phase 5: coder-daemon + .claude.json propagation"

# Mimic verify.sh's architect→shared sync so the planner has .claude.json
# in its volume. (The full verify.sh would also chown / chmod the shared
# volume mount root, which we already did in Phase 1.)
docker run --rm \
    -v "${vol_arch}:/src:ro" \
    -v "${vol_shared}:/dst" \
    debian:bookworm-slim \
    sh -c '
        if [ -f /src/.claude.json ]; then
            cp /src/.claude.json /dst/.claude.json
            chmod 600 /dst/.claude.json
            chown 1000:1000 /dst/.claude.json
        fi
    '
if docker run --rm -v "${vol_shared}:/v:ro" debian:bookworm-slim test -f /v/.claude.json; then
    pass ".claude.json propagated into shared volume (architect → shared)"
else
    fail ".claude.json missing from shared volume after propagation"
fi

ce up -d coder-daemon >/dev/null
for _ in $(seq 1 30); do
    if ce logs coder-daemon 2>&1 | grep -q "coder-daemon listening"; then
        break
    fi
    sleep 1
done
if ce logs coder-daemon 2>&1 | grep -q "coder-daemon listening"; then
    pass "coder-daemon up and listening"
else
    fail "coder-daemon failed to bind"
    ce logs coder-daemon 2>&1 | tail -20
    exit 1
fi

# Stub claude. The daemon spawns 'claude' from PATH; /usr/local/bin
# precedes /usr/bin in the daemon image's PATH, so a binary placed there
# shadows the apt-installed one. The stub:
#   - confirms CLAUDE.md (the s007 7.c inline anchor) exists
#   - writes the expected report file at briefs/<section>/<task>.report.md
#   - commits and pushes to the task branch
#   - exits 0
stub_dir="${work_dir}/stub"
mkdir -p "${stub_dir}"
cat > "${stub_dir}/claude" <<'STUB_EOF'
#!/bin/bash
# Stub claude for substrate-end-to-end test. Args from the daemon are
# ignored; the stub locates the brief by searching the working tree.
set -euo pipefail
cd "$(pwd)"
[ -f CLAUDE.md ] || { echo "[stub] FAIL: CLAUDE.md missing in workdir" >&2; exit 1; }
brief=$(ls briefs/*/t*.brief.md 2>/dev/null | head -n1)
if [ -z "${brief}" ]; then
    echo "[stub] FAIL: no task brief found in briefs/" >&2
    exit 1
fi
report="${brief%.brief.md}.report.md"
cat > "${report}" <<RPT
# Stub task report

Generated by the substrate-end-to-end test stub claude. The real coder
would have done the work; this confirms the daemon's commission
mechanics drive a coder subshell to a clean exit.

- Brief:  ${brief}
- Branch: $(git rev-parse --abbrev-ref HEAD)
RPT
git -c user.email=coder@substrate.local -c user.name=coder add "${report}"
git -c user.email=coder@substrate.local -c user.name=coder commit -q -m "stub: task report"
git push -q origin "$(git rev-parse --abbrev-ref HEAD)"
exit 0
STUB_EOF
chmod 0755 "${stub_dir}/claude"
docker cp "${stub_dir}/claude" "${project}-daemon:/usr/local/bin/claude"
if ce exec -T -u agent coder-daemon sh -c 'command -v claude' | grep -q '/usr/local/bin/claude'; then
    pass "stub claude installed at /usr/local/bin/claude inside daemon"
else
    fail "stub claude PATH override did not take effect"
fi

# ---------------------------------------------------------------------------
# Phase 6 — bring up planner; verify entrypoint outcomes; drive a commission
# ---------------------------------------------------------------------------
hr; echo "Phase 6: planner entrypoint + synthetic commission"

ce up -d planner >/dev/null
# planner has no container_name; resolve dynamically via compose ps
planner_cid=""
for _ in $(seq 1 30); do
    planner_cid=$(ce ps -q planner 2>/dev/null | head -n1)
    if [ -n "${planner_cid}" ] && \
       docker exec -u agent "${planner_cid}" test -L /home/agent/.claude.json 2>/dev/null && \
       docker exec -u agent "${planner_cid}" test -d /work/.git 2>/dev/null; then
        break
    fi
    sleep 1
done
if [ -z "${planner_cid}" ]; then
    fail "planner container did not start"
    exit 1
fi
pass "planner up (cid=${planner_cid:0:12})"

if docker exec -u agent "${planner_cid}" test -L /home/agent/.claude.json && \
   [ "$(docker exec -u agent "${planner_cid}" readlink /home/agent/.claude.json | tr -d '\r')" = \
     "/home/agent/.claude/.claude.json" ]; then
    pass "planner: ~/.claude.json is a symlink → /home/agent/.claude/.claude.json"
else
    fail "planner: ~/.claude.json symlink missing or wrong target"
fi

if docker exec -u agent "${planner_cid}" test -L /work/CLAUDE.md && \
   [ "$(docker exec -u agent "${planner_cid}" readlink /work/CLAUDE.md | tr -d '\r')" = \
     "/methodology/planner-guide.md" ]; then
    pass "planner: /work/CLAUDE.md is a symlink → /methodology/planner-guide.md"
else
    fail "planner: /work/CLAUDE.md symlink missing or wrong target"
fi

# Confirm the planner sees a populated .claude.json (architect's, propagated
# in Phase 5). Without this the planner's claude-code session would be
# treated as a fresh install and prompt for OAuth.
if docker exec -u agent "${planner_cid}" test -s /home/agent/.claude/.claude.json; then
    pass "planner: .claude.json present and non-empty in shared volume"
else
    fail "planner: .claude.json missing or empty — claude-code would prompt for OAuth"
fi

# Drive a commission against the daemon. The planner already has curl
# absent? Let's try; fall back to a one-shot helper container if not.
have_curl=0
if docker exec -u agent "${planner_cid}" sh -c 'command -v curl >/dev/null 2>&1'; then
    have_curl=1
fi
if [ "${have_curl}" -eq 1 ]; then
    note "POSTing /commission from planner via curl"
    commission_resp=$(docker exec -u agent "${planner_cid}" sh -c "
        curl -fsS -X POST \
          -H 'Authorization: Bearer ${COMMISSION_TOKEN}' \
          -H 'Content-Type: application/json' \
          -d '{\"brief_path\":\"briefs/test-section/t001-stub.brief.md\",\"section_branch\":\"section/test-section\",\"task_branch\":\"task/test-section.001-stub\"}' \
          http://coder-daemon:${COMMISSION_PORT}/commission
    ")
else
    note "planner has no curl; using a one-shot helper container on the test network"
    commission_resp=$(docker run --rm \
        --network "${network}" \
        curlimages/curl:8.10.1 \
        -fsS -X POST \
        -H "Authorization: Bearer ${COMMISSION_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"brief_path\":\"briefs/test-section/t001-stub.brief.md\",\"section_branch\":\"section/test-section\",\"task_branch\":\"task/test-section.001-stub\"}" \
        "http://coder-daemon:${COMMISSION_PORT}/commission")
fi

commission_id=$(printf '%s' "${commission_resp}" | sed -n 's/.*"commission_id" *: *"\([^"]*\)".*/\1/p')
if [ -n "${commission_id}" ]; then
    pass "POST /commission accepted (commission_id=${commission_id:0:8}, no 503)"
else
    fail "POST /commission did not return a commission_id (response: ${commission_resp})"
    ce logs coder-daemon 2>&1 | tail -20
    exit 1
fi

# Poll /commission/<id>/wait until terminal.
note "polling /commission/${commission_id:0:8}.../wait"
final=""
for _ in $(seq 1 12); do
    if [ "${have_curl}" -eq 1 ]; then
        wait_resp=$(docker exec -u agent "${planner_cid}" sh -c "
            curl -fsS -H 'Authorization: Bearer ${COMMISSION_TOKEN}' \
                'http://coder-daemon:${COMMISSION_PORT}/commission/${commission_id}/wait?timeout=30'
        " 2>/dev/null) || wait_resp=""
    else
        wait_resp=$(docker run --rm --network "${network}" \
            curlimages/curl:8.10.1 \
            -fsS -H "Authorization: Bearer ${COMMISSION_TOKEN}" \
            "http://coder-daemon:${COMMISSION_PORT}/commission/${commission_id}/wait?timeout=30" \
            2>/dev/null) || wait_resp=""
    fi
    status=$(printf '%s' "${wait_resp}" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')
    if [ "${status}" = "complete" ] || [ "${status}" = "failed" ]; then
        final="${wait_resp}"
        break
    fi
done

if [ -z "${final}" ]; then
    fail "commission did not reach a terminal status"
    ce logs coder-daemon 2>&1 | tail -30
    exit 1
fi

status=$(printf '%s' "${final}" | sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')
exit_code=$(printf '%s' "${final}" | sed -n 's/.*"exit_code" *: *\([0-9-]*\).*/\1/p')
report_path=$(printf '%s' "${final}" | sed -n 's/.*"report_path" *: *"\([^"]*\)".*/\1/p')
err=$(printf '%s' "${final}" | sed -n 's/.*"error" *: *"\([^"]*\)".*/\1/p')

if [ "${status}" = "complete" ] && [ "${exit_code}" = "0" ] && \
   [ "${report_path}" = "briefs/test-section/t001-stub.report.md" ]; then
    pass "synthetic-coder commission completed: status=complete, exit=0, report at ${report_path}"
else
    fail "synthetic-coder commission did not complete cleanly (status='${status}' exit='${exit_code}' report='${report_path}' error='${err}')"
    ce logs coder-daemon 2>&1 | tail -30
fi

# Confirm the report actually landed on origin (the daemon's check
# already verifies this, but assert independently).
if ce exec -T git-server git --git-dir=/srv/git/main.git \
    cat-file -e "task/test-section.001-stub:briefs/test-section/t001-stub.report.md" 2>/dev/null; then
    pass "report file present at task-branch tip on origin"
else
    fail "report file missing on origin/task/test-section.001-stub"
fi

# ---------------------------------------------------------------------------
# Phase 7 — s008 8.f: commission-pair.sh bad-slug fails fast
# ---------------------------------------------------------------------------
hr; echo "Phase 7: commission-pair.sh bad-slug failure (s008)"

# Invoke commission-pair.sh directly with a slug whose brief doesn't exist.
# Override ARCHITECT_CONTAINER so check-brief.sh queries the test's scratch
# architect (the host's agent-architect may not be running). The script
# should exit non-zero before any docker-compose interaction.
bad_slug="s999-does-not-exist-${test_pid}"
bad_brief_path="briefs/${bad_slug}/section.brief.md"
bad_out=$(ARCHITECT_CONTAINER="${project}-architect" \
    bash "${repo_root}/commission-pair.sh" "${bad_slug}" 2>&1)
bad_rc=$?

if [ "${bad_rc}" -ne 0 ]; then
    pass "commission-pair.sh bad-slug exited non-zero (rc=${bad_rc})"
else
    fail "commission-pair.sh bad-slug exited 0 (expected non-zero)"
fi

if printf '%s' "${bad_out}" | grep -qF "${bad_brief_path}"; then
    pass "bad-slug error message names the missing brief path"
else
    fail "bad-slug error message did not mention '${bad_brief_path}' (got: ${bad_out})"
fi

# Confirm no scratch project leaked from the failed run. The script's
# project name template is "${repo_root_basename}-${section}".
leaked_project="$(basename "${repo_root}")-${bad_slug}"
if [ -z "$(docker compose -p "${leaked_project}" ps -q 2>/dev/null)" ]; then
    pass "no compose containers leaked under '${leaked_project}'"
else
    fail "compose containers leaked under '${leaked_project}' — bad-slug should exit before bringing anything up"
    docker compose -p "${leaked_project}" --profile ephemeral down -v --remove-orphans >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Phase 8 — s008 8.f: planner entrypoint passes BOOTSTRAP_PROMPT to claude
# ---------------------------------------------------------------------------
hr; echo "Phase 8: planner BOOTSTRAP_PROMPT passthrough (s008)"

# Stub claude that records its arguments into the shared volume and exits.
# Mounted at /usr/local/bin/claude so it shadows the real binary in
# /usr/bin. The entrypoint will invoke it as 'claude -p "<prompt>"', so
# $1='-p' and $2 is the bootstrap prompt itself.
mkdir -p "${stub_dir}"
cat > "${stub_dir}/planner-claude" <<'STUB_EOF'
#!/bin/bash
# Stub claude for s008 bootstrap-passthrough test.
marker=/home/agent/.claude/bootstrap-stub-marker
{
    echo "stub-claude-invoked"
    echo "argc=$#"
    echo "arg1=${1:-}"
    echo "arg2=${2:-}"
} > "${marker}"
exit 0
STUB_EOF
chmod 0755 "${stub_dir}/planner-claude"

# Pre-clear any stale marker from a previous run (paranoia; the volume is
# fresh per test invocation, but the helper container makes this cheap).
docker run --rm -v "${vol_shared}:/v" debian:bookworm-slim \
    rm -f /v/bootstrap-stub-marker >/dev/null 2>&1 || true

bootstrap_sentinel="bootstrap-passthrough-${test_pid}"

# 'compose run --rm -T' allocates no TTY and inherits the test's stdin
# (which we redirect from /dev/null). After the stub exits, the entrypoint
# reaches 'exec bash -l'; bash sees EOF on stdin and exits 0, so the
# container exits cleanly without hanging on a tty.
ce run --rm -T \
    -e BOOTSTRAP_PROMPT="${bootstrap_sentinel}" \
    -v "${stub_dir}/planner-claude:/usr/local/bin/claude:ro" \
    planner </dev/null >"${work_dir}/planner-bootstrap.out" 2>&1
planner_rc=$?

if [ "${planner_rc}" -eq 0 ]; then
    pass "planner ran with BOOTSTRAP_PROMPT and exited 0"
else
    fail "planner exited ${planner_rc} with BOOTSTRAP_PROMPT (expected 0)"
fi

# Always show the captured output (helps diagnose env / mount issues).
note "planner-bootstrap.out tail:"
tail -30 "${work_dir}/planner-bootstrap.out" 2>/dev/null | sed 's/^/  /' || true

if grep -qF "Bootstrap prompt detected" "${work_dir}/planner-bootstrap.out"; then
    pass "entrypoint logged 'Bootstrap prompt detected' banner"
else
    fail "entrypoint did not log the bootstrap-detected banner"
fi

if grep -qF "Claude discharged. Dropping to interactive shell." "${work_dir}/planner-bootstrap.out"; then
    pass "entrypoint logged the post-discharge banner (reached bash -l)"
else
    fail "entrypoint did not log the post-discharge banner"
fi

marker_content=$(docker run --rm -v "${vol_shared}:/v:ro" debian:bookworm-slim \
    cat /v/bootstrap-stub-marker 2>/dev/null || true)

if printf '%s' "${marker_content}" | grep -qx 'stub-claude-invoked'; then
    pass "stub claude was invoked by the entrypoint"
else
    fail "stub claude was NOT invoked (marker missing or unexpected: '${marker_content}')"
fi

if printf '%s' "${marker_content}" | grep -qx 'arg1=-p'; then
    pass "stub claude received '-p' as first argument"
else
    fail "stub claude did not receive '-p' (got: ${marker_content})"
fi

if printf '%s' "${marker_content}" | grep -qxF "arg2=${bootstrap_sentinel}"; then
    pass "stub claude received the BOOTSTRAP_PROMPT sentinel as second argument"
else
    fail "stub claude did not receive the bootstrap sentinel (got: ${marker_content})"
fi

# ===========================================================================
# s009 phases 9–16: platform plugin model.
#
# These phases differ from 0–8 in two ways:
#
#   1. They exercise the build path (renderer → docker build → toolchain
#      assertions inside the resulting image), which means each phase that
#      needs a toolchain runs a real `docker build`. Setup time is
#      noticeably longer than the s007/s008 phases (typically several
#      minutes for the apt-only platforms and longer for ones that pip-
#      install or curl-install).
#
#   2. Each phase scaffolds and tears down its own platform-specific
#      scratch state — generated Dockerfile.generated, override file,
#      .substrate-state directory, and per-phase image tags. The single
#      scratch substrate from phases 1–8 (network, volumes, env file)
#      remains usable for the architect-mount checks in phase 9 / 10.
#
# Phase 14 uses /dev/null as a stand-in for real ESP32 hardware: the
# wiring path (arg-parse → state-file → compose-override → container-
# visible) can be exercised against any host device. Real-hardware
# verification is out-of-band.
# ===========================================================================

# Per-phase image tag suffix so each phase's docker build doesn't
# clobber the host's canonical agent-*:latest tags.
s009_tag() { echo "test-s009-${test_pid}-$1"; }

# Build a role image with a phase-tagged name from the rendered
# Dockerfile.generated. role=coder-daemon|auditor; tag=phase suffix.
# Returns 0 on success, non-zero on failure (and emits the build log
# tail to help diagnose).
s009_build_role() {
    local role="$1" phase="$2" platforms="$3"
    local tag; tag=$(s009_tag "${phase}-${role}")
    "${repo_root}/infra/scripts/render-dockerfile.sh" "${role}" "${platforms}" >/dev/null
    if ! docker build -q -t "agent-${role}:${tag}" \
            -f "${repo_root}/infra/${role}/Dockerfile.generated" \
            "${repo_root}/infra/${role}" >"${work_dir}/${phase}-${role}-build.log" 2>&1; then
        note "${phase}/${role} build log tail:"
        tail -20 "${work_dir}/${phase}-${role}-build.log" | sed 's/^/  /'
        return 1
    fi
    echo "agent-${role}:${tag}"
}

# Drop a phase-specific .substrate-state directory and override file
# before its assertions; cleaned up at teardown.
s009_phase_state_dir() {
    local phase="$1"
    local d="${work_dir}/${phase}-state"
    mkdir -p "${d}"
    echo "${d}"
}

# Track tags built per phase so the trap can rmi them all on exit.
s009_tags_to_rmi=()

# Phase 11 rebuilds the canonical agent-coder-daemon:latest /
# agent-auditor:latest tags as part of exercising --add-platform. Snap
# the pre-test image IDs so the cleanup can restore them by re-tagging
# (no rebuild required — image IDs survive the rebuild as untagged).
s009_pretest_coder_id=""
s009_pretest_auditor_id=""
# BuildKit may prune the previous image when re-tagging via 'docker
# compose build', so a bare image-ID snapshot doesn't survive phase 11's
# rebuild. Snapshot via a stable tag instead — the tag holds the image
# alive as long as it exists, regardless of what happens to :latest.
s009_pretest_coder_tag="agent-coder-daemon:s009-pretest-${test_pid}"
s009_pretest_auditor_tag="agent-auditor:s009-pretest-${test_pid}"
s009_snapshot_role_images() {
    if docker image inspect agent-coder-daemon:latest >/dev/null 2>&1; then
        docker tag agent-coder-daemon:latest "${s009_pretest_coder_tag}" >/dev/null 2>&1 || true
        s009_pretest_coder_id=$(docker image inspect "${s009_pretest_coder_tag}" \
            --format '{{.Id}}' 2>/dev/null || true)
    fi
    if docker image inspect agent-auditor:latest >/dev/null 2>&1; then
        docker tag agent-auditor:latest "${s009_pretest_auditor_tag}" >/dev/null 2>&1 || true
        s009_pretest_auditor_id=$(docker image inspect "${s009_pretest_auditor_tag}" \
            --format '{{.Id}}' 2>/dev/null || true)
    fi
}
s009_restore_role_images() {
    if docker image inspect "${s009_pretest_coder_tag}" >/dev/null 2>&1; then
        docker tag "${s009_pretest_coder_tag}" agent-coder-daemon:latest >/dev/null 2>&1 || true
        docker image rm "${s009_pretest_coder_tag}" >/dev/null 2>&1 || true
    fi
    if docker image inspect "${s009_pretest_auditor_tag}" >/dev/null 2>&1; then
        docker tag "${s009_pretest_auditor_tag}" agent-auditor:latest >/dev/null 2>&1 || true
        docker image rm "${s009_pretest_auditor_tag}" >/dev/null 2>&1 || true
    fi
}

s009_extra_cleanup() {
    s009_restore_role_images
    for t in "${s009_tags_to_rmi[@]:-}"; do
        [ -z "${t}" ] && continue
        docker image rm -f "${t}" >/dev/null 2>&1 || true
    done
    docker container rm -f "test-s009-${test_pid}-running-planner" >/dev/null 2>&1 || true
    docker container rm -f "test-s009-${test_pid}-pending-gs" >/dev/null 2>&1 || true
    docker network rm "test-s009-${test_pid}-net" >/dev/null 2>&1 || true
    rm -f "${repo_root}/docker-compose.override.yml" \
          "${repo_root}/docker-compose.override.yml.s009-saved"
    rm -f "${repo_root}/infra/coder-daemon/Dockerfile.generated" \
          "${repo_root}/infra/auditor/Dockerfile.generated"
}

# Wire s009 cleanup into the existing trap. The original cleanup_test
# is renamed to _s007_cleanup_test so we can call it from the wrapper.
eval "_s007_cleanup_test() $(declare -f cleanup_test | sed -n '/^{/,$p')"
cleanup_test() {
    s009_extra_cleanup
    _s007_cleanup_test
}

# Snapshot the canonical role image IDs once, BEFORE any s009 phase
# rebuilds them, so the trap can restore them at exit (phase 11 mutates
# agent-coder-daemon:latest and agent-auditor:latest as part of testing
# --add-platform's full path).
s009_snapshot_role_images

# ---------------------------------------------------------------------------
# Phase 9 — single-platform setup (go)
# ---------------------------------------------------------------------------
hr; echo "Phase 9: single-platform setup (--platform=go)"

if ! coder_tag=$(s009_build_role coder-daemon 9 go); then
    fail "phase 9: failed to build coder-daemon with --platform=go"
else
    s009_tags_to_rmi+=("${coder_tag}")
    pass "phase 9: coder-daemon built with --platform=go (tag=${coder_tag})"
fi
if ! auditor_tag=$(s009_build_role auditor 9 go); then
    fail "phase 9: failed to build auditor with --platform=go"
else
    s009_tags_to_rmi+=("${auditor_tag}")
    pass "phase 9: auditor built with --platform=go (tag=${auditor_tag})"
fi

# (i) go version runs in coder-daemon image
if docker run --rm --entrypoint bash "${coder_tag}" -c 'go version' >/dev/null 2>&1; then
    pass "phase 9 (i): 'go version' runs inside ${coder_tag}"
else
    fail "phase 9 (i): 'go version' did NOT run inside ${coder_tag}"
fi
# (ii) go version runs in auditor image
if docker run --rm --entrypoint bash "${auditor_tag}" -c 'go version' >/dev/null 2>&1; then
    pass "phase 9 (ii): 'go version' runs inside ${auditor_tag}"
else
    fail "phase 9 (ii): 'go version' did NOT run inside ${auditor_tag}"
fi

# (iii) and (iv): write platforms.txt to a phase scratch dir, mount it
# into a one-shot container with SUBSTRATE_PLATFORMS env, and verify
# the architect contract from the host's perspective.
phase9_state=$(s009_phase_state_dir 9)
echo go > "${phase9_state}/platforms.txt"
: > "${phase9_state}/devices.txt"

env_check=$(docker run --rm \
    -v "${phase9_state}:/substrate:ro" \
    -e SUBSTRATE_PLATFORMS=go \
    debian:bookworm-slim \
    bash -lc 'cat /substrate/platforms.txt; echo --; printf "%s\n" "${SUBSTRATE_PLATFORMS}"' 2>&1)
if printf '%s' "${env_check}" | grep -qx 'go' && \
   printf '%s' "${env_check}" | grep -qx 'go' >/dev/null; then
    # The first 'go' is the file content; the second is the env var (after --).
    if printf '%s' "${env_check}" | awk -v RS='--' 'NR==1 && /go/ {a=1} NR==2 && /go/ {b=1} END{exit !(a && b)}'; then
        pass "phase 9 (iii)+(iv): SUBSTRATE_PLATFORMS env and /substrate/platforms.txt both contain 'go'"
    else
        fail "phase 9 (iii)+(iv): unexpected check output: ${env_check}"
    fi
else
    fail "phase 9 (iii)+(iv): unexpected check output: ${env_check}"
fi

# ---------------------------------------------------------------------------
# Phase 10 — polyglot setup (--platform=go,python-extras)
# ---------------------------------------------------------------------------
hr; echo "Phase 10: polyglot setup (--platform=go,python-extras)"

if ! coder10=$(s009_build_role coder-daemon 10 go,python-extras); then
    fail "phase 10: failed to build coder-daemon with --platform=go,python-extras"
else
    s009_tags_to_rmi+=("${coder10}")
    pass "phase 10: coder-daemon built with --platform=go,python-extras"
fi
if ! auditor10=$(s009_build_role auditor 10 go,python-extras); then
    fail "phase 10: failed to build auditor with --platform=go,python-extras"
else
    s009_tags_to_rmi+=("${auditor10}")
    pass "phase 10: auditor built with --platform=go,python-extras"
fi

for tag in "${coder10}" "${auditor10}"; do
    role="${tag#agent-}"; role="${role%%:*}"
    if docker run --rm --entrypoint bash "${tag}" -c 'go version && uv --version' >/dev/null 2>&1; then
        pass "phase 10: both 'go version' and 'uv --version' run inside ${tag}"
    else
        fail "phase 10: one of go/uv missing inside ${tag}"
        # Diagnostic: show which one failed.
        docker run --rm --entrypoint bash "${tag}" -c 'echo PATH=$PATH; go version 2>&1; uv --version 2>&1' \
            2>&1 | sed 's/^/  /' | head -5
    fi
done

phase10_state=$(s009_phase_state_dir 10)
printf '%s\n' "go" "python-extras" > "${phase10_state}/platforms.txt"
got=$(docker run --rm -v "${phase10_state}:/substrate:ro" \
    debian:bookworm-slim cat /substrate/platforms.txt | tr -d '\r' | sort | paste -sd ',')
if [ "${got}" = "go,python-extras" ]; then
    pass "phase 10: /substrate/platforms.txt contains both names"
else
    fail "phase 10: /substrate/platforms.txt content unexpected: ${got}"
fi

# ---------------------------------------------------------------------------
# Phase 11 — --add-platform happy path
# ---------------------------------------------------------------------------
hr; echo "Phase 11: --add-platform happy path"

# Start at platforms=go (the phase 9 build produced agent-coder-daemon:
# test-s009-${pid}-9-coder-daemon). For phase 11 we'll re-render with
# --add-platform=c-cpp on top of go (apt-only, fast) and assert the new
# state file lists both, and the rebuilt image carries g++.

phase11_state=$(s009_phase_state_dir 11)
echo go > "${phase11_state}/platforms.txt"
: > "${phase11_state}/devices.txt"

# Drive add-platform-device.sh with phase-scoped env. We point
# GIT_SERVER_CONTAINER at a non-existent name to force the "git-server
# down" branch into a deterministic NO-pending state via --force; OR
# point it at a healthy scratch git-server. Cleanest: bring a scratch
# git-server up briefly so the pre-flight (b) check is real.

# Reuse the test's existing scratch git-server (ce). It already runs.
SUBSTRATE_ADD_PLATFORM=c-cpp \
SUBSTRATE_FORCE=0 \
GIT_SERVER_CONTAINER="${project}-git-server" \
ROLE_IMAGE_PATTERNS="agent-${test_pid}-nonexistent:latest" \
PLATFORM_REPO_ROOT="${repo_root}" \
HOME="${work_dir}/phase11-home" \
bash -c '
    cd "'"${repo_root}"'"
    # Use the phase11 state dir, not the host substrate.
    export _ORIG_STATE_DIR="'"${repo_root}/.substrate-state"'"
    if [ -e "${_ORIG_STATE_DIR}" ]; then
        mv "${_ORIG_STATE_DIR}" "${_ORIG_STATE_DIR}.s009-saved"
    fi
    cp -r "'"${phase11_state}"'" "${_ORIG_STATE_DIR}"
    bash "'"${repo_root}"'/infra/scripts/add-platform-device.sh"
    rc=$?
    # Capture the resulting state file BEFORE we restore.
    cp -r "${_ORIG_STATE_DIR}/platforms.txt" "'"${phase11_state}"'/platforms.txt"
    rm -rf "${_ORIG_STATE_DIR}"
    if [ -e "${_ORIG_STATE_DIR}.s009-saved" ]; then
        mv "${_ORIG_STATE_DIR}.s009-saved" "${_ORIG_STATE_DIR}"
    fi
    exit $rc
' >"${work_dir}/phase11.out" 2>&1
phase11_rc=$?

if [ "${phase11_rc}" -eq 0 ]; then
    pass "phase 11: --add-platform=c-cpp succeeded (rc=0)"
else
    fail "phase 11: --add-platform=c-cpp failed rc=${phase11_rc}"
    note "phase 11 log tail:"
    tail -20 "${work_dir}/phase11.out" | sed 's/^/  /'
fi

phase11_final=$(paste -sd ',' "${phase11_state}/platforms.txt" 2>/dev/null | tr -d '\r')
if [ "${phase11_final}" = "go,c-cpp" ]; then
    pass "phase 11: state file updated to 'go,c-cpp'"
else
    fail "phase 11: state file expected 'go,c-cpp', got '${phase11_final}'"
fi

# Track the rebuilt agent-coder-daemon:latest so the final cleanup
# resets it to whatever the host had originally.
# (The add-platform-device.sh rebuilds the canonical agent-coder-daemon:
# latest tag; the test annotates this in the report. The trap clears
# the work dir but the rebuilt :latest tag remains and will be
# overwritten the next time the user re-runs ./setup-linux.sh.)

# ---------------------------------------------------------------------------
# Phase 12 — --add-platform refusal: running container
# ---------------------------------------------------------------------------
hr; echo "Phase 12: --add-platform refusal — running container"

# Spawn a container running the canonical agent-planner:latest image
# so the running-container pre-flight trips. Use 'sleep' so the
# container stays up.
docker network create "test-s009-${test_pid}-net" >/dev/null 2>&1 || true
running_planner="test-s009-${test_pid}-running-planner"
docker run -d --rm \
    --name "${running_planner}" \
    --entrypoint sleep \
    --network "test-s009-${test_pid}-net" \
    agent-planner:latest 60 >/dev/null

phase12_state=$(s009_phase_state_dir 12)
echo go > "${phase12_state}/platforms.txt"

SUBSTRATE_ADD_PLATFORM=c-cpp \
SUBSTRATE_FORCE=0 \
GIT_SERVER_CONTAINER="${project}-git-server" \
PLATFORM_REPO_ROOT="${repo_root}" \
bash -c '
    cd "'"${repo_root}"'"
    export _ORIG_STATE_DIR="'"${repo_root}/.substrate-state"'"
    if [ -e "${_ORIG_STATE_DIR}" ]; then
        mv "${_ORIG_STATE_DIR}" "${_ORIG_STATE_DIR}.s009-saved"
    fi
    cp -r "'"${phase12_state}"'" "${_ORIG_STATE_DIR}"
    bash "'"${repo_root}"'/infra/scripts/add-platform-device.sh"
    rc=$?
    cp -r "${_ORIG_STATE_DIR}/platforms.txt" "'"${phase12_state}"'/platforms.txt"
    rm -rf "${_ORIG_STATE_DIR}"
    if [ -e "${_ORIG_STATE_DIR}.s009-saved" ]; then
        mv "${_ORIG_STATE_DIR}.s009-saved" "${_ORIG_STATE_DIR}"
    fi
    exit $rc
' >"${work_dir}/phase12.out" 2>&1
phase12_rc=$?

if [ "${phase12_rc}" -ne 0 ]; then
    pass "phase 12: --add-platform refused (rc=${phase12_rc})"
else
    fail "phase 12: --add-platform was NOT refused (expected non-zero exit)"
fi
if grep -qF "${running_planner}" "${work_dir}/phase12.out"; then
    pass "phase 12: error message names the running planner container"
else
    fail "phase 12: error message did not mention '${running_planner}'"
    note "phase 12 log tail:"
    tail -10 "${work_dir}/phase12.out" | sed 's/^/  /'
fi
phase12_final=$(paste -sd ',' "${phase12_state}/platforms.txt" 2>/dev/null | tr -d '\r')
if [ "${phase12_final}" = "go" ]; then
    pass "phase 12: state file unchanged"
else
    fail "phase 12: state file mutated despite refusal: '${phase12_final}'"
fi

docker rm -f "${running_planner}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Phase 13 — --add-platform refusal: pending section branch
# ---------------------------------------------------------------------------
hr; echo "Phase 13: --add-platform refusal — pending section branch"

# Push a section/* branch with commits ahead of main into the test's
# scratch git-server. The architect test compose seeded main earlier
# (Phase 4); we reuse that bare repo, add a section branch with one
# more commit, and let the pre-flight (b) check trip.

docker run --rm \
    -v "${keys_dir}/human:/k:ro" \
    --network "${network}" \
    debian:bookworm-slim \
    sh -c '
        apt-get update -qq >/dev/null 2>&1 && \
            apt-get install -qq -y --no-install-recommends git openssh-client >/dev/null 2>&1
        export GIT_SSH_COMMAND="ssh -i /k/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
        tmp=$(mktemp -d)
        cd "$tmp"
        git -c user.email=h -c user.name=h clone -q git@git-server:/srv/git/main.git .
        git checkout -q -b section/phase13-pending
        echo "phase13" > pending.txt
        git -c user.email=h -c user.name=h add pending.txt
        git -c user.email=h -c user.name=h commit -q -m "phase13 pending"
        git push -q origin section/phase13-pending
    ' >/dev/null 2>&1 || true

phase13_state=$(s009_phase_state_dir 13)
echo go > "${phase13_state}/platforms.txt"

SUBSTRATE_ADD_PLATFORM=c-cpp \
SUBSTRATE_FORCE=0 \
GIT_SERVER_CONTAINER="${project}-git-server" \
ROLE_IMAGE_PATTERNS="agent-${test_pid}-nonexistent:latest" \
PLATFORM_REPO_ROOT="${repo_root}" \
bash -c '
    cd "'"${repo_root}"'"
    export _ORIG_STATE_DIR="'"${repo_root}/.substrate-state"'"
    if [ -e "${_ORIG_STATE_DIR}" ]; then
        mv "${_ORIG_STATE_DIR}" "${_ORIG_STATE_DIR}.s009-saved"
    fi
    cp -r "'"${phase13_state}"'" "${_ORIG_STATE_DIR}"
    bash "'"${repo_root}"'/infra/scripts/add-platform-device.sh"
    rc=$?
    cp -r "${_ORIG_STATE_DIR}/platforms.txt" "'"${phase13_state}"'/platforms.txt"
    rm -rf "${_ORIG_STATE_DIR}"
    if [ -e "${_ORIG_STATE_DIR}.s009-saved" ]; then
        mv "${_ORIG_STATE_DIR}.s009-saved" "${_ORIG_STATE_DIR}"
    fi
    exit $rc
' >"${work_dir}/phase13.out" 2>&1
phase13_rc=$?

if [ "${phase13_rc}" -ne 0 ]; then
    pass "phase 13: --add-platform refused (rc=${phase13_rc})"
else
    fail "phase 13: --add-platform was NOT refused (expected non-zero exit)"
fi
if grep -qF "section/phase13-pending" "${work_dir}/phase13.out"; then
    pass "phase 13: error message names the pending section branch"
else
    fail "phase 13: error message did not mention 'section/phase13-pending'"
    note "phase 13 log tail:"
    tail -10 "${work_dir}/phase13.out" | sed 's/^/  /'
fi
phase13_final=$(paste -sd ',' "${phase13_state}/platforms.txt" 2>/dev/null | tr -d '\r')
if [ "${phase13_final}" = "go" ]; then
    pass "phase 13: state file unchanged"
else
    fail "phase 13: state file mutated despite refusal: '${phase13_final}'"
fi

# ---------------------------------------------------------------------------
# Phase 14 — device passthrough wiring
# ---------------------------------------------------------------------------
hr; echo "Phase 14: device passthrough wiring (--device=/dev/null)"

phase14_state=$(s009_phase_state_dir 14)
phase14_dir="${work_dir}/phase14"
mkdir -p "${phase14_dir}"

# Render the override file at the phase scratch dir.
(cd "${phase14_dir}" && \
    "${repo_root}/infra/scripts/render-device-override.sh" /dev/null) >/dev/null 2>&1 || true
# render-device-override.sh writes to repo_root/docker-compose.override.yml,
# not to cwd; relocate the output into the phase scratch dir manually.
"${repo_root}/infra/scripts/render-device-override.sh" /dev/null >/dev/null 2>&1 || true
mv "${repo_root}/docker-compose.override.yml" "${phase14_dir}/docker-compose.override.yml"

if grep -qF "/dev/null:/dev/null" "${phase14_dir}/docker-compose.override.yml"; then
    pass "phase 14: override file contains /dev/null:/dev/null entry"
else
    fail "phase 14: override file missing /dev/null entry"
    cat "${phase14_dir}/docker-compose.override.yml" | sed 's/^/  /'
fi

# Write the substrate state to scratch and assert /substrate/devices.txt
# contains /dev/null when mounted.
echo "/dev/null" > "${phase14_state}/devices.txt"
got_dev=$(docker run --rm -v "${phase14_state}:/substrate:ro" \
    debian:bookworm-slim cat /substrate/devices.txt | tr -d '\r')
if [ "${got_dev}" = "/dev/null" ]; then
    pass "phase 14: /substrate/devices.txt contains /dev/null"
else
    fail "phase 14: /substrate/devices.txt content unexpected: ${got_dev}"
fi

# Verify the device is actually visible inside a container when the
# wiring is applied. Use 'docker run --device' directly (the override
# file's purpose is to tell compose to do the same — testing the
# device is reachable proves the underlying mechanism works).
if docker run --rm --device /dev/null:/dev/null --entrypoint ls \
    agent-coder-daemon:latest -la /dev/null >/dev/null 2>&1; then
    pass "phase 14: --device wiring exposes /dev/null inside coder-daemon"
else
    fail "phase 14: --device wiring did NOT expose /dev/null"
fi

# Also exercise compose autoload (the production code path). Build a
# tiny scratch compose.yml and place the override alongside; compose
# should pick up devices via autoload.
compose_scratch="${phase14_dir}/compose-test"
mkdir -p "${compose_scratch}"
# The production override.yml extends both coder-daemon and auditor;
# the scratch base must declare both services or compose's merge will
# error on the missing image/build context for the role we don't use.
cat > "${compose_scratch}/docker-compose.yml" <<COMPOSE_EOF
services:
  coder-daemon:
    image: agent-coder-daemon:latest
  auditor:
    image: agent-auditor:latest
COMPOSE_EOF
cp "${phase14_dir}/docker-compose.override.yml" "${compose_scratch}/docker-compose.override.yml"
if (cd "${compose_scratch}" && \
    docker compose -p "test-s009-${test_pid}-14" run --rm \
        --entrypoint ls coder-daemon -la /dev/null >/dev/null 2>&1); then
    pass "phase 14: compose autoload of override.yml wires /dev/null"
else
    fail "phase 14: compose autoload of override.yml did NOT expose /dev/null"
fi
docker compose -p "test-s009-${test_pid}-14" --profile ephemeral down --remove-orphans >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Phase 15 — device_required warning (no --device)
# ---------------------------------------------------------------------------
hr; echo "Phase 15: device_required warning"

# Drive platform_args_finalize directly with --platform=platformio-esp32
# and no --device; assert SUBSTRATE_DEVICE_REQUIRED_MISSING is set, and
# the warning text was emitted on stderr.
phase15_out=$(bash -c '
    set -euo pipefail
    repo_root="'"${repo_root}"'"
    . "${repo_root}/infra/scripts/lib/platform-args.sh"
    platform_args_init
    platform_args_consume --platform=platformio-esp32
    platform_args_finalize
    echo "SUBSTRATE_DEVICE_REQUIRED_MISSING=${SUBSTRATE_DEVICE_REQUIRED_MISSING}"
    echo "EXIT=0"
' 2>&1)
phase15_rc=$?

if [ "${phase15_rc}" -eq 0 ] && \
   printf '%s' "${phase15_out}" | grep -qF "SUBSTRATE_DEVICE_REQUIRED_MISSING=platformio-esp32|"; then
    pass "phase 15: setup proceeds (rc=0); SUBSTRATE_DEVICE_REQUIRED_MISSING populated"
else
    fail "phase 15: unexpected outcome rc=${phase15_rc}"
    note "phase 15 output:"
    printf '%s\n' "${phase15_out}" | sed 's/^/  /'
fi
if printf '%s' "${phase15_out}" | grep -qF "device_required=true" && \
   printf '%s' "${phase15_out}" | grep -qF "platformio-esp32"; then
    pass "phase 15: warning text mentions device_required and platformio-esp32"
else
    fail "phase 15: warning text incomplete"
fi

# ---------------------------------------------------------------------------
# Phase 16 — --add-device happy path
# ---------------------------------------------------------------------------
hr; echo "Phase 16: --add-device happy path"

phase16_state=$(s009_phase_state_dir 16)
echo platformio-esp32 > "${phase16_state}/platforms.txt"
: > "${phase16_state}/devices.txt"

# Snapshot the host's coder-daemon image creation timestamp so we can
# verify --add-device does NOT trigger a rebuild.
img_before=$(docker image inspect agent-coder-daemon:latest --format '{{.Id}}' 2>/dev/null || echo missing)

SUBSTRATE_ADD_DEVICES=/dev/null \
SUBSTRATE_FORCE=0 \
GIT_SERVER_CONTAINER="${project}-git-server" \
ROLE_IMAGE_PATTERNS="agent-${test_pid}-nonexistent:latest" \
PLATFORM_REPO_ROOT="${repo_root}" \
bash -c '
    cd "'"${repo_root}"'"
    export _ORIG_STATE_DIR="'"${repo_root}/.substrate-state"'"
    if [ -e "${_ORIG_STATE_DIR}" ]; then
        mv "${_ORIG_STATE_DIR}" "${_ORIG_STATE_DIR}.s009-saved"
    fi
    cp -r "'"${phase16_state}"'" "${_ORIG_STATE_DIR}"
    bash "'"${repo_root}"'/infra/scripts/add-platform-device.sh"
    rc=$?
    cp -r "${_ORIG_STATE_DIR}/devices.txt" "'"${phase16_state}"'/devices.txt"
    rm -f "'"${repo_root}"'/docker-compose.override.yml" || true
    rm -rf "${_ORIG_STATE_DIR}"
    if [ -e "${_ORIG_STATE_DIR}.s009-saved" ]; then
        mv "${_ORIG_STATE_DIR}.s009-saved" "${_ORIG_STATE_DIR}"
    fi
    exit $rc
' >"${work_dir}/phase16.out" 2>&1
phase16_rc=$?

if [ "${phase16_rc}" -eq 0 ]; then
    pass "phase 16: --add-device=/dev/null succeeded"
else
    fail "phase 16: --add-device=/dev/null failed rc=${phase16_rc}"
    note "phase 16 log tail:"
    tail -10 "${work_dir}/phase16.out" | sed 's/^/  /'
fi
phase16_final=$(paste -sd ',' "${phase16_state}/devices.txt" 2>/dev/null | tr -d '\r')
if [ "${phase16_final}" = "/dev/null" ]; then
    pass "phase 16: state file devices.txt updated to /dev/null"
else
    fail "phase 16: devices.txt content unexpected: '${phase16_final}'"
fi

img_after=$(docker image inspect agent-coder-daemon:latest --format '{{.Id}}' 2>/dev/null || echo missing)
if [ "${img_before}" = "${img_after}" ]; then
    pass "phase 16: agent-coder-daemon:latest image ID unchanged (no rebuild)"
else
    fail "phase 16: agent-coder-daemon:latest image ID changed (rebuild happened — should not for --add-device)"
fi

# ===========================================================================
# Phase 17 — s010 remote-host registration loopback.
#
# Brings up two alpine+sshd sidecar containers as "remote targets" on
# the test's scratch network, pre-installs an operator bootstrap key in
# each (simulating the operator's pre-existing passwordless SSH+sudo
# access from their shell), runs the substrate's bootstrap-remote-host.sh
# against the first target, asserts the artifacts (per-host key file,
# known-hosts entry, state-file row, ssh-config stanza, audit-log
# capture from a stub coder-daemon), then exercises --add-remote-host
# against the second target and asserts the same artifacts plus
# functional reachability of both.
#
# Hardware-less by design — the real-hardware fixture (T-Dongle-S3 on
# the Orange Pi) is the manual procedure at
# infra/scripts/tests/manual/remote-host-tdongle.md.
# ===========================================================================
hr; echo "Phase 17: remote-host registration loopback (s010)"

phase17_dir="${work_dir}/phase17"
mkdir -p "${phase17_dir}"

# Operator bootstrap keypair — used once to install the substrate's
# pubkey on each sidecar (mirroring the precondition that the operator
# already has passwordless SSH+sudo to the target before registering).
ssh-keygen -t ed25519 -N '' \
    -f "${phase17_dir}/operator_id_ed25519" \
    -C "phase17-operator" -q

# Build the alpine+sshd image. Pre-install the operator's pubkey in the
# sidecar's authorized_keys so step 4 of bootstrap can connect non-
# interactively.
cp "${phase17_dir}/operator_id_ed25519.pub" "${phase17_dir}/authorized_keys"
cat > "${phase17_dir}/Dockerfile" <<'DOCKERFILE'
FROM alpine:3.19
RUN apk add --no-cache openssh-server bash sudo python3 \
 && ssh-keygen -A \
 && adduser -D -s /bin/bash s010user \
 && echo 's010user:s010-phase17-password' | chpasswd \
 && echo 's010user ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/s010user \
 && chmod 0440 /etc/sudoers.d/s010user \
 && mkdir -p /home/s010user/.ssh \
 && chown s010user:s010user /home/s010user/.ssh \
 && chmod 0700 /home/s010user/.ssh
COPY authorized_keys /home/s010user/.ssh/authorized_keys
RUN chown s010user:s010user /home/s010user/.ssh/authorized_keys \
 && chmod 0600 /home/s010user/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE

phase17_sshd_image="test-s010-${test_pid}-sshd"
if docker build -q -t "${phase17_sshd_image}:latest" \
        "${phase17_dir}" >"${phase17_dir}/build.log" 2>&1; then
    pass "phase 17: sshd sidecar image built"
    s009_tags_to_rmi+=("${phase17_sshd_image}:latest")
else
    fail "phase 17: sshd sidecar image build failed"
    tail -10 "${phase17_dir}/build.log" | sed 's/^/  /'
    # No point continuing the phase without sidecars.
    docker rm -f "test-s010-${test_pid}-sshd1" "test-s010-${test_pid}-sshd2" >/dev/null 2>&1 || true
    hr
    printf "Summary: ${GREEN}%d passed${NC}, " "${pass_count}"
    if [ "${fail_count}" -gt 0 ]; then
        printf "${RED}%d failed${NC}\n" "${fail_count}"
        exit 1
    fi
    printf "${GREEN}%d failed${NC}\n" "${fail_count}"
    exit 0
fi

# Spin up two sidecars on the test's scratch network so the bootstrap
# can reach them by container IP. agent-coder-daemon (when later run on
# the same network) reaches them by the same IP, which is what the
# rendered ssh-config stanza will reference.
phase17_sidecar_1="test-s010-${test_pid}-sshd1"
phase17_sidecar_2="test-s010-${test_pid}-sshd2"
docker run -d --rm --name "${phase17_sidecar_1}" \
    --network "${network}" \
    "${phase17_sshd_image}:latest" >/dev/null
docker run -d --rm --name "${phase17_sidecar_2}" \
    --network "${network}" \
    "${phase17_sshd_image}:latest" >/dev/null

# Cleanup wiring — cover the case where the test bails out during
# this phase.
phase17_cleanup() {
    docker rm -f "${phase17_sidecar_1}" "${phase17_sidecar_2}" >/dev/null 2>&1 || true
}
eval "_pre17_s007_cleanup_test() $(declare -f cleanup_test | sed -n '/^{/,$p')"
cleanup_test() {
    phase17_cleanup
    _pre17_s007_cleanup_test
}

# Wait for both sshd's to bind.
sleep 2
sidecar_1_ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${network}"'").IPAddress}}' "${phase17_sidecar_1}")
sidecar_2_ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "'"${network}"'").IPAddress}}' "${phase17_sidecar_2}")
if [ -n "${sidecar_1_ip}" ] && [ -n "${sidecar_2_ip}" ]; then
    pass "phase 17: sidecars up at ${sidecar_1_ip} / ${sidecar_2_ip}"
else
    fail "phase 17: sidecar IPs missing (1='${sidecar_1_ip}' 2='${sidecar_2_ip}')"
fi

# Phase 17 uses an isolated substrate state directory + isolated keys
# tree so the host's real registrations aren't touched. The bootstrap
# script and validator both honor REMOTE_HOST_REPO_ROOT when sourced
# directly, but as scripts they look at the script-relative repo root.
# We swap-and-restore the repo's .substrate-state and infra/keys/
# remote-hosts/ for the duration of phase 17.
phase17_state_save=""
phase17_keys_save=""
phase17_role_keys_save=""
if [ -e "${repo_root}/.substrate-state" ]; then
    phase17_state_save="${repo_root}/.substrate-state.s010-saved-${test_pid}"
    mv "${repo_root}/.substrate-state" "${phase17_state_save}"
fi
if [ -d "${repo_root}/infra/keys/remote-hosts" ]; then
    phase17_keys_save="${repo_root}/infra/keys/remote-hosts.s010-saved-${test_pid}"
    mv "${repo_root}/infra/keys/remote-hosts" "${phase17_keys_save}"
fi
mkdir -p "${repo_root}/infra/keys/remote-hosts" "${repo_root}/.substrate-state"
chmod 0700 "${repo_root}/infra/keys/remote-hosts"
# Snapshot any pre-existing per-role config files so we can restore
# them at end of phase. These may exist if the human has run setup
# with --remote-host already.
for role in architect coder auditor; do
    if [ -f "${repo_root}/infra/keys/${role}/config" ]; then
        cp "${repo_root}/infra/keys/${role}/config" \
            "${phase17_dir}/role-${role}-config.saved" 2>/dev/null || true
    fi
done

phase17_restore() {
    rm -rf "${repo_root}/.substrate-state" \
           "${repo_root}/infra/keys/remote-hosts" 2>/dev/null || true
    if [ -n "${phase17_state_save}" ] && [ -e "${phase17_state_save}" ]; then
        mv "${phase17_state_save}" "${repo_root}/.substrate-state"
    fi
    if [ -n "${phase17_keys_save}" ] && [ -e "${phase17_keys_save}" ]; then
        mv "${phase17_keys_save}" "${repo_root}/infra/keys/remote-hosts"
    fi
    for role in architect coder auditor; do
        if [ -f "${phase17_dir}/role-${role}-config.saved" ]; then
            cp "${phase17_dir}/role-${role}-config.saved" \
                "${repo_root}/infra/keys/${role}/config" 2>/dev/null || true
        else
            rm -f "${repo_root}/infra/keys/${role}/config" 2>/dev/null || true
        fi
    done
}
# Wire restore into the cleanup chain too.
eval "_pre17b_cleanup_test() $(declare -f cleanup_test | sed -n '/^{/,$p')"
cleanup_test() {
    phase17_restore
    _pre17b_cleanup_test
}

# An ssh-agent loaded with the operator key — the bootstrap's step 4
# uses the operator's loaded credentials (no -i flag). step 5
# (verification) sets IdentitiesOnly=yes + -F /dev/null, which excludes
# agent identities, so it gets the substrate-key-only auth we want.
eval "$(ssh-agent -s)" >/dev/null
phase17_agent_pid="${SSH_AGENT_PID:-}"
ssh-add "${phase17_dir}/operator_id_ed25519" >/dev/null 2>&1
phase17_agent_cleanup() {
    if [ -n "${phase17_agent_pid}" ]; then
        kill "${phase17_agent_pid}" >/dev/null 2>&1 || true
    fi
}
eval "_pre17c_cleanup_test() $(declare -f cleanup_test | sed -n '/^{/,$p')"
cleanup_test() {
    phase17_agent_cleanup
    _pre17c_cleanup_test
}

# Initial registration — drive bootstrap-remote-host.sh directly.
SUBSTRATE_REMOTE_HOSTS="ci-target=s010user@${sidecar_1_ip}:22" \
bash "${repo_root}/infra/scripts/bootstrap-remote-host.sh" \
    >"${phase17_dir}/bootstrap-1.log" 2>&1
phase17_rc=$?

if [ "${phase17_rc}" -eq 0 ]; then
    pass "phase 17: bootstrap-remote-host.sh succeeded for ci-target"
else
    fail "phase 17: bootstrap-remote-host.sh failed (rc=${phase17_rc})"
    tail -20 "${phase17_dir}/bootstrap-1.log" | sed 's/^/  /'
fi

bash "${repo_root}/infra/scripts/render-ssh-config.sh" >/dev/null 2>&1

# Artifact assertions.
if [ -f "${repo_root}/infra/keys/remote-hosts/ci-target/id_ed25519" ]; then
    pass "phase 17: per-host private key present"
else
    fail "phase 17: per-host private key missing"
fi
if grep -qF "${sidecar_1_ip}" "${repo_root}/.substrate-state/known-hosts" 2>/dev/null; then
    pass "phase 17: known-hosts contains the sidecar's host key"
else
    fail "phase 17: known-hosts missing the sidecar entry"
fi
if grep -qE "^ci-target	s010user	${sidecar_1_ip}	22\$" "${repo_root}/.substrate-state/remote-hosts.txt" 2>/dev/null; then
    pass "phase 17: remote-hosts.txt has ci-target row"
else
    fail "phase 17: remote-hosts.txt row mismatch"
fi
if grep -qF "Host ci-target" "${repo_root}/.substrate-state/ssh-config" 2>/dev/null; then
    pass "phase 17: ssh-config has 'Host ci-target' stanza"
else
    fail "phase 17: ssh-config missing ci-target stanza"
fi
if [ -f "${repo_root}/infra/keys/coder/config" ] && \
   grep -qF "Host ci-target" "${repo_root}/infra/keys/coder/config"; then
    pass "phase 17: per-role config (coder) mirrors the canonical ssh-config"
else
    fail "phase 17: per-role config (coder) missing or stale"
fi

# Reachability from a stub coder-daemon-style container, with the
# wrapper installed. WORKDIR=/work picks up the audit log there.
phase17_workdir="${phase17_dir}/work"
mkdir -p "${phase17_workdir}"
chmod 0777 "${phase17_workdir}"

phase17_run_in_container() {
    docker run --rm \
        --network "${network}" \
        -v "${repo_root}/infra/keys/coder:/home/agent/.ssh:ro" \
        -v "${repo_root}/infra/keys/remote-hosts:/home/agent/.ssh-remote-hosts:ro" \
        -v "${repo_root}/.substrate-state/known-hosts:/home/agent/.ssh-known-hosts:ro" \
        -v "${repo_root}/infra/scripts/agent-ssh-audited.sh:/usr/local/bin/ssh:ro" \
        -v "${phase17_workdir}:/work" \
        -e WORKDIR=/work \
        -u 1000:1000 \
        --entrypoint bash \
        agent-coder-daemon:latest \
        -c "$1"
}

if phase17_run_in_container 'ssh ci-target true' >/dev/null 2>&1; then
    pass "phase 17: 'ssh ci-target true' from coder-daemon returns 0"
else
    fail "phase 17: 'ssh ci-target true' did not exit 0"
fi

if [ -s "${phase17_workdir}/.substrate-ssh.log" ] && \
   grep -qF 'ssh ci-target' "${phase17_workdir}/.substrate-ssh.log"; then
    pass "phase 17: audit log captured the ssh invocation"
else
    fail "phase 17: audit log empty or missing ci-target line"
fi

# --add-remote-host on the running substrate. The phase has no
# ephemeral-role containers running (the test compose project has
# planner / coder-daemon scaled to zero or only ran one-shot earlier),
# but to be safe we set ROLE_IMAGE_PATTERNS to a no-op so the pre-flight
# refusal doesn't trip on the leftover stub-coder image from earlier
# phases.
SUBSTRATE_ADD_REMOTE_HOST="ci-target-2=s010user@${sidecar_2_ip}:22" \
SUBSTRATE_FORCE=0 \
ROLE_IMAGE_PATTERNS="agent-${test_pid}-no-such-image:latest" \
PLATFORM_REPO_ROOT="${repo_root}" \
bash "${repo_root}/infra/scripts/add-platform-device.sh" \
    >"${phase17_dir}/add-rh.log" 2>&1
phase17_add_rc=$?

if [ "${phase17_add_rc}" -eq 0 ]; then
    pass "phase 17: --add-remote-host=ci-target-2 succeeded"
else
    fail "phase 17: --add-remote-host failed (rc=${phase17_add_rc})"
    tail -20 "${phase17_dir}/add-rh.log" | sed 's/^/  /'
fi

if grep -qE "^ci-target-2	s010user	${sidecar_2_ip}	22\$" "${repo_root}/.substrate-state/remote-hosts.txt" 2>/dev/null; then
    pass "phase 17: remote-hosts.txt now has ci-target-2 row"
else
    fail "phase 17: ci-target-2 row missing after add"
fi

# Both hosts reachable from the same container; ssh-config has both.
if phase17_run_in_container 'set -e; ssh ci-target true; ssh ci-target-2 true' >/dev/null 2>&1; then
    pass "phase 17: both ci-target and ci-target-2 reachable from coder-daemon"
else
    fail "phase 17: at least one of ci-target / ci-target-2 not reachable"
fi

# Idempotency: re-bootstrap of an already-registered host short-circuits.
SUBSTRATE_REMOTE_HOSTS="ci-target=s010user@${sidecar_1_ip}:22" \
bash "${repo_root}/infra/scripts/bootstrap-remote-host.sh" \
    >"${phase17_dir}/idempotent.log" 2>&1
if grep -qF "already registered, skipping" "${phase17_dir}/idempotent.log"; then
    pass "phase 17: re-bootstrap of ci-target hits the idempotency short-circuit"
else
    fail "phase 17: idempotency short-circuit not observed"
    tail -10 "${phase17_dir}/idempotent.log" | sed 's/^/  /'
fi

# Duplicate-name refusal on --add-remote-host.
SUBSTRATE_ADD_REMOTE_HOST="ci-target=s010user@${sidecar_2_ip}:22" \
SUBSTRATE_FORCE=0 \
ROLE_IMAGE_PATTERNS="agent-${test_pid}-no-such-image:latest" \
PLATFORM_REPO_ROOT="${repo_root}" \
bash "${repo_root}/infra/scripts/add-platform-device.sh" \
    >"${phase17_dir}/dup.log" 2>&1
phase17_dup_rc=$?
if [ "${phase17_dup_rc}" -ne 0 ] && \
   grep -qF "already registered" "${phase17_dir}/dup.log"; then
    pass "phase 17: --add-remote-host duplicate-name refused with the expected diagnostic"
else
    fail "phase 17: duplicate-name was not refused (rc=${phase17_dup_rc})"
    tail -10 "${phase17_dir}/dup.log" | sed 's/^/  /'
fi

# Restore. cleanup_test will run the same on exit, but we run it now so
# the phase's footprint disappears even if a later phase is added.
phase17_restore
phase17_agent_cleanup
docker rm -f "${phase17_sidecar_1}" "${phase17_sidecar_2}" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
hr
printf "Summary: ${GREEN}%d passed${NC}, " "${pass_count}"
if [ "${fail_count}" -gt 0 ]; then
    printf "${RED}%d failed${NC}\n" "${fail_count}"
    exit 1
fi
printf "${GREEN}%d failed${NC}\n" "${fail_count}"
exit 0
