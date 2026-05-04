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

# ---------------------------------------------------------------------------
hr
printf "Summary: ${GREEN}%d passed${NC}, " "${pass_count}"
if [ "${fail_count}" -gt 0 ]; then
    printf "${RED}%d failed${NC}\n" "${fail_count}"
    exit 1
fi
printf "${GREEN}%d failed${NC}\n" "${fail_count}"
exit 0
