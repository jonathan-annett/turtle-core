#!/bin/bash
# test-onboarder-shell.sh — end-to-end verification for s012 (onboarder shell).
#
# Scaffolds an isolated scratch substrate (parallel to test-substrate-end-
# to-end.sh's pattern), drives the onboarder against a synthetic type-1
# source tree with a stub claude binary, verifies:
#   - main.git has the expected two-commit shape ("onboarding: import
#     source materials" then "onboarding: handover brief"),
#   - briefs/onboarding/handover.md exists and contains all nine sections
#     specified by the handover template (presence check by header grep),
#   - the architect entrypoint detects the handover on restart and
#     invokes its first claude session against it (Option α of A.6).
#
# Real claude-code execution is NOT exercised — the test injects a stub
# `claude` binary into the onboarder and architect images via per-`compose
# run` volume mounts, mirroring the s007/s008 pattern. The stub for the
# onboarder writes a valid nine-section handover and pushes it; the stub
# for the architect records the fact that it was invoked.
#
# Required: agent-{base,onboarder,architect,git-server} images already
# built (`./setup-linux.sh` or `./setup-mac.sh`).
#
# Run:
#   bash infra/scripts/tests/test-onboarder-shell.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_pid=$$
project="turtle-core-test-s012-${test_pid}"
network="${project}-net"

vol_arch="${project}-claude-state-architect"
vol_shared="${project}-claude-state-shared"
vol_main_bare="${project}-main-bare"
vol_auditor_bare="${project}-auditor-bare"
vol_arch_workspace="${project}-architect-workspace"
vol_arch_auditor_clone="${project}-architect-auditor-clone"

work_dir="/tmp/${project}"
keys_dir="${work_dir}/keys"
source_dir="${work_dir}/source"
stub_dir="${work_dir}/stub"
compose_file="${work_dir}/docker-compose.yml"
env_file="${work_dir}/env"

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

req_imgs=(agent-base agent-onboarder agent-architect agent-git-server)
missing=0
for img in "${req_imgs[@]}"; do
    if ! docker image inspect "${img}:latest" >/dev/null 2>&1; then
        fail "image '${img}:latest' is missing — run setup-linux.sh / setup-mac.sh first"
        missing=1
    fi
done
[ "${missing}" -eq 0 ] && pass "all required images present"
if [ "${missing}" -ne 0 ]; then
    note "stopping: cannot exercise the onboarder without the role images"
    exit 1
fi

# ---------------------------------------------------------------------------
# Phase 1 — scaffold scratch substrate (keys, network, volumes, compose file)
# ---------------------------------------------------------------------------
hr; echo "Phase 1: scaffold scratch substrate"

mkdir -p "${keys_dir}"/{architect,onboarder,human}
chmod 700 "${keys_dir}"
chmod 700 "${keys_dir}"/*
for role in architect onboarder human; do
    ssh-keygen -t ed25519 -N '' -C "${role}@${project}" \
        -f "${keys_dir}/${role}/id_ed25519" -q >/dev/null 2>&1
    chmod 600 "${keys_dir}/${role}/id_ed25519"
done
pass "generated scratch ssh keys (architect, onboarder, human)"

docker network create "${network}" >/dev/null
pass "created scratch network '${network}'"

for vol in "${vol_arch}" "${vol_shared}" "${vol_main_bare}" "${vol_auditor_bare}" \
           "${vol_arch_workspace}" "${vol_arch_auditor_clone}"; do
    docker volume create "${vol}" >/dev/null
done
docker run --rm \
    -v "${vol_arch}:/a" -v "${vol_shared}:/s" \
    debian:bookworm-slim \
    sh -c 'chown 1000:1000 /a /s && chmod 0700 /a /s' >/dev/null
pass "created scratch volumes (mount-roots normalised)"

# Touch the .claude.json sentinel inside both architect and shared so
# claude (real or stubbed) wouldn't be triggered into a fresh-OAuth path
# at the entrypoints. The stub doesn't care, but pre-seeding matches the
# steady-state shape and removes a spurious source of test flake.
docker run --rm -v "${vol_arch}:/v" debian:bookworm-slim \
    sh -c 'echo "{}" > /v/.claude.json && chown 1000:1000 /v/.claude.json && chmod 600 /v/.claude.json' \
    >/dev/null
docker run --rm -v "${vol_shared}:/v" debian:bookworm-slim \
    sh -c 'echo "{}" > /v/.claude.json && chown 1000:1000 /v/.claude.json && chmod 600 /v/.claude.json' \
    >/dev/null

cat > "${env_file}" <<ENV_EOF
SOURCE_PATH=${source_dir}
INTAKE_FILE=/dev/null
ONBOARDING_TYPE_HINT=1
ENV_EOF

cat > "${compose_file}" <<COMPOSE_EOF
# Generated for onboarder-shell test (pid ${test_pid}).
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

  onboarder:
    image: agent-onboarder:latest
    profiles: ["ephemeral"]
    depends_on: [git-server]
    environment:
      ONBOARDING_TYPE_HINT: \${ONBOARDING_TYPE_HINT:-unknown}
    volumes:
      - ${vol_shared}:/home/agent/.claude
      - ${repo_root}/methodology:/methodology:ro
      - ${keys_dir}/onboarder:/home/agent/.ssh:ro
      - \${SOURCE_PATH:-/dev/null}:/source:ro
      - \${INTAKE_FILE:-/dev/null}:/onboarding-intake.md:ro
    networks: [agent-net]
    stdin_open: true
    tty: true

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

networks:
  agent-net:
    external: true
    name: ${network}
COMPOSE_EOF

pass "wrote scratch compose + env files"

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
    pass "git-server up; main.git + auditor.git initialised"
else
    fail "git-server failed to init bare repos"
    exit 1
fi

# Verify the git-server's authorized_keys recognises the onboarder role
# (s012 A.4 added it). The entrypoint logs each role it loads a key for.
if ce logs git-server 2>&1 | grep -q 'Authorized key loaded for role: onboarder'; then
    pass "git-server entrypoint loaded the onboarder key (s012 A.4)"
else
    fail "git-server did not log onboarder key load — entrypoint roles list may be missing 'onboarder'"
fi

# Verify main.git starts at the initial empty commit (commit-count=1).
initial_count=$(ce exec -T git-server git --git-dir=/srv/git/main.git rev-list --count main 2>/dev/null | tr -d '\r\n ')
if [ "${initial_count}" = "1" ]; then
    pass "main.git contains exactly the initial empty commit"
else
    fail "main.git commit-count is ${initial_count} (expected 1)"
fi

# ---------------------------------------------------------------------------
# Phase 3 — bring up architect; smoke-check entrypoint
# ---------------------------------------------------------------------------
hr; echo "Phase 3: scratch architect (bootstrap block dormant — no handover yet)"

ce up -d architect >/dev/null
for _ in $(seq 1 30); do
    if ce exec -T -u agent architect test -L /work/CLAUDE.md 2>/dev/null; then
        break
    fi
    sleep 1
done

if ce exec -T -u agent architect test -L /work/CLAUDE.md; then
    pass "architect: /work/CLAUDE.md symlink in place (entrypoint completed)"
else
    fail "architect: /work/CLAUDE.md missing (entrypoint did not complete)"
fi

if ce exec -T -u agent architect test ! -f /work/briefs/onboarding/handover.md; then
    pass "architect: no handover yet (correct — onboarding has not run)"
else
    fail "architect: unexpected handover present in /work before onboarding ran"
fi

# Architect logs should NOT contain the bootstrap-detected banner before
# onboarding (greenfield-equivalent state).
if ! ce logs architect 2>&1 | grep -q 'Onboarding handover detected'; then
    pass "architect: bootstrap block dormant (no 'Onboarding handover detected' in logs)"
else
    fail "architect: bootstrap block fired despite no handover present"
fi

# ---------------------------------------------------------------------------
# Phase 4 — synthetic type-1 source tree
# ---------------------------------------------------------------------------
hr; echo "Phase 4: synthetic type-1 source tree"

mkdir -p "${source_dir}"
cat > "${source_dir}/README.md" <<'README_EOF'
# legacy-thing

A minimal type-1 fixture. Code only, no docs, no agent history,
no informal methodology.
README_EOF
cat > "${source_dir}/main.py" <<'SRC_EOF'
#!/usr/bin/env python3
def main():
    print("hello from the type-1 fixture")

if __name__ == "__main__":
    main()
SRC_EOF
chmod 0755 "${source_dir}/main.py"
pass "synthetic source tree at ${source_dir} (README.md + main.py)"

# ---------------------------------------------------------------------------
# Phase 5 — perform the source-tree import using the scratch onboarder key
# ---------------------------------------------------------------------------
hr; echo "Phase 5: source-tree import commit (onboarder identity)"

if docker run --rm \
        -v "${keys_dir}/onboarder:/k:ro" \
        -v "${source_dir}:/src:ro" \
        --network "${network}" \
        debian:bookworm-slim \
        sh -c '
            set -e
            apt-get update -qq >/dev/null 2>&1
            apt-get install -qq -y --no-install-recommends git openssh-client ca-certificates >/dev/null 2>&1
            cp /k/id_ed25519 /tmp/key
            chmod 600 /tmp/key
            export GIT_SSH_COMMAND="ssh -i /tmp/key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
            tmp=$(mktemp -d)
            cd "$tmp"
            git clone -q git@git-server:/srv/git/main.git .
            cp -a /src/. .
            # cp -a preserves source UID/GID (likely 1000 from host) while
            # the temp clone is root-owned; normalise to avoid git
            # "dubious ownership" rejection. Same fix in onboard-project.sh.
            chown -R root:root .
            git -c user.email=onboarder@substrate.local -c user.name=onboarder add -A
            git -c user.email=onboarder@substrate.local -c user.name=onboarder commit -q -m "onboarding: import source materials"
            git -c user.email=onboarder@substrate.local -c user.name=onboarder push -q origin main
        ' >/dev/null 2>&1; then
    pass "source import push succeeded (onboarder credentials accepted by git-server hook)"
else
    fail "source import push failed — git-server hook may be rejecting onboarder pushes to main"
    exit 1
fi

import_count=$(ce exec -T git-server git --git-dir=/srv/git/main.git rev-list --count main | tr -d '\r\n ')
if [ "${import_count}" = "2" ]; then
    pass "main.git now has 2 commits (initial empty + source import)"
else
    fail "expected 2 commits after import; got ${import_count}"
fi

import_msg=$(ce exec -T git-server git --git-dir=/srv/git/main.git log -1 --format=%s main | tr -d '\r')
if [ "${import_msg}" = "onboarding: import source materials" ]; then
    pass "import commit subject is 'onboarding: import source materials'"
else
    fail "import commit subject mismatched (got: '${import_msg}')"
fi

# ---------------------------------------------------------------------------
# Phase 6 — run the onboarder with a stubbed claude that writes a 9-section
# handover, commits, pushes
# ---------------------------------------------------------------------------
hr; echo "Phase 6: onboarder run with stub claude (writes handover, pushes)"

mkdir -p "${stub_dir}"
cat > "${stub_dir}/onboarder-claude" <<'STUB_EOF'
#!/bin/bash
# Stub claude for s012 onboarder test. Writes a valid 9-section handover,
# commits with the canonical message, pushes to main, exits 0. Ignores
# all incoming args — the real claude would consume the BOOTSTRAP_PROMPT
# and interact with the operator; the stub just produces the artifact the
# operator-script-flow expects.
set -euo pipefail
cd /work
mkdir -p briefs/onboarding
cat > briefs/onboarding/handover.md <<'HANDOVER_EOF'
# Onboarding handover brief (test fixture)

Generated by test-onboarder-shell.sh's stub claude. Confirms the
onboarder's compose service, entrypoint, key plumbing, and git-server
hook all line up end-to-end.

## 1. Project identity

- Name: legacy-thing
- Source location: /tmp/turtle-core-test-s012-*/source
- Stack: Python (minimal)
- Methodology state: none
- Type: 1 (code only, no history, no informal methodology)

## 2. Source materials inventory

Two files at the source root: a README and a main.py. No tests, no
docs directory, no agent transcripts.

## 3. Code structural review

No automated code migration review run; sub-agent ships in Section B.
The single source file (main.py) defines `main()` and a `__main__`
guard.

## 4. History review

N/A (type 1 — code only, no history materials).

## 5. SHARED-STATE.md candidate

(Candidate — architect refines.)

- Single entry point at main.py.
- No external dependencies observed.

## 6. TOP-LEVEL-PLAN.md candidate

(Candidate — architect and human ratify.)

- s001-hello-cleanup: rationalise the entry point and add a tests/ directory.

## 7. Known unknowns

- Is the project intended to grow beyond a single script? Operator did
  not say; affects whether s001 introduces packaging.

## 8. Operator's stated priorities

- Operator was the stub; no real priorities were elicited.

## 9. Carry-over hazards

None observed.
HANDOVER_EOF

git -c user.email=onboarder@substrate.local -c user.name=onboarder \
    add briefs/onboarding/handover.md
git -c user.email=onboarder@substrate.local -c user.name=onboarder \
    commit -q -m "onboarding: handover brief"
git push -q origin main
exit 0
STUB_EOF
chmod 0755 "${stub_dir}/onboarder-claude"

# Pre-clear any stale marker from a previous run.
docker run --rm -v "${vol_shared}:/v" debian:bookworm-slim \
    rm -f /v/onboarder-bootstrap-marker >/dev/null 2>&1 || true

bootstrap_sentinel="onboarder-bootstrap-passthrough-${test_pid}"

# Use 'compose run --rm -T' (no TTY, inherits stdin from /dev/null) so
# the entrypoint's `exec bash -l` exits cleanly on EOF after claude
# discharges. Same trick the s007 phase 8 planner-bootstrap test uses.
SOURCE_PATH="${source_dir}" \
INTAKE_FILE=/dev/null \
ONBOARDING_TYPE_HINT=1 \
ce run --rm -T \
    -e BOOTSTRAP_PROMPT="${bootstrap_sentinel}" \
    -e ONBOARDING_TYPE_HINT=1 \
    -v "${stub_dir}/onboarder-claude:/usr/local/bin/claude:ro" \
    onboarder </dev/null >"${work_dir}/onboarder-run.out" 2>&1
onboarder_rc=$?

if [ "${onboarder_rc}" -eq 0 ]; then
    pass "onboarder container ran and exited 0"
else
    fail "onboarder container exited ${onboarder_rc} (expected 0)"
fi

note "onboarder-run.out tail:"
tail -25 "${work_dir}/onboarder-run.out" 2>/dev/null | sed 's/^/  /' || true

if grep -qF "Bootstrap prompt detected" "${work_dir}/onboarder-run.out"; then
    pass "onboarder entrypoint logged 'Bootstrap prompt detected' banner"
else
    fail "onboarder entrypoint did not log bootstrap-detected banner"
fi

if grep -qF "Claude discharged. Dropping to interactive shell." "${work_dir}/onboarder-run.out"; then
    pass "onboarder entrypoint logged post-discharge banner (reached bash -l)"
else
    fail "onboarder entrypoint did not log post-discharge banner"
fi

# ---------------------------------------------------------------------------
# Phase 7 — verify state on main.git
# ---------------------------------------------------------------------------
hr; echo "Phase 7: verify main.git state after onboarding"

final_count=$(ce exec -T git-server git --git-dir=/srv/git/main.git rev-list --count main | tr -d '\r\n ')
if [ "${final_count}" = "3" ]; then
    pass "main.git now has 3 commits (initial + import + handover)"
else
    fail "expected 3 commits after onboarding; got ${final_count}"
fi

handover_msg=$(ce exec -T git-server git --git-dir=/srv/git/main.git log -1 --format=%s main | tr -d '\r')
if [ "${handover_msg}" = "onboarding: handover brief" ]; then
    pass "handover commit subject is 'onboarding: handover brief'"
else
    fail "handover commit subject mismatched (got: '${handover_msg}')"
fi

# Verify the canonical commit ordering: parent of HEAD is the import commit.
parent_msg=$(ce exec -T git-server git --git-dir=/srv/git/main.git log -1 --format=%s main^ | tr -d '\r')
if [ "${parent_msg}" = "onboarding: import source materials" ]; then
    pass "handover commit's parent is the source-import commit"
else
    fail "handover commit's parent is unexpected (got: '${parent_msg}')"
fi

# ---------------------------------------------------------------------------
# Phase 8 — handover file presence + nine-section structure
# ---------------------------------------------------------------------------
hr; echo "Phase 8: handover file content (9 sections present)"

handover_blob=$(ce exec -T git-server \
    git --git-dir=/srv/git/main.git show "main:briefs/onboarding/handover.md" 2>/dev/null)

if [ -n "${handover_blob}" ]; then
    pass "handover.md exists in main and is non-empty"
else
    fail "handover.md is missing or empty on main"
fi

expected_headings=(
    '^## 1\. Project identity$'
    '^## 2\. Source materials inventory$'
    '^## 3\. Code structural review$'
    '^## 4\. History review$'
    '^## 5\. SHARED-STATE\.md candidate$'
    '^## 6\. TOP-LEVEL-PLAN\.md candidate$'
    '^## 7\. Known unknowns$'
    '^## 8\. Operator'"'"'s stated priorities$'
    '^## 9\. Carry-over hazards$'
)
all_present=1
for pattern in "${expected_headings[@]}"; do
    if printf '%s' "${handover_blob}" | grep -Eq "${pattern}"; then
        :
    else
        all_present=0
        note "missing heading matching: ${pattern}"
    fi
done
if [ "${all_present}" -eq 1 ]; then
    pass "all 9 handover headings present (presence check, not content quality)"
else
    fail "one or more required headings missing from handover.md"
fi

# ---------------------------------------------------------------------------
# Phase 9 — architect first-attach bootstrap (Option α of A.6)
# ---------------------------------------------------------------------------
hr; echo "Phase 9: architect first-attach bootstrap detects handover"

# Stub claude for the architect: records that it was invoked + with what
# first arg. The architect entrypoint's bootstrap block runs `claude
# "<prompt>"` (no --print mode), so $1 is the prompt itself.
cat > "${stub_dir}/architect-claude" <<'STUB_EOF'
#!/bin/bash
# Stub claude for s012 architect first-attach test.
marker=/home/agent/.claude/architect-bootstrap-marker
{
    echo "stub-claude-invoked"
    echo "argc=$#"
    # Truncate arg1 to first 100 chars for the marker — the real bootstrap
    # prompt is long; we only need to verify the architect entrypoint
    # passed *something handover-pointing* in.
    arg1_head=$(printf '%s' "${1:-}" | head -c 100)
    echo "arg1_head=${arg1_head}"
} > "${marker}"
exit 0
STUB_EOF
chmod 0755 "${stub_dir}/architect-claude"

# Pre-clear any stale marker.
docker run --rm -v "${vol_arch}:/v" debian:bookworm-slim \
    rm -f /v/architect-bootstrap-marker >/dev/null 2>&1 || true

# Stop architect, then start it back up with the stub claude mounted.
# 'compose stop' + 'compose run --rm -T' doesn't reattach to the
# named container_name. Use 'docker' directly so we can mount the
# stub and pass stdin=/dev/null without TTY.
ce stop architect >/dev/null 2>&1

# The architect entrypoint's bootstrap block runs `claude` synchronously
# then drops to `bash -l`. Running this through `docker compose start`
# wouldn't capture stdout/stderr of the entrypoint. Instead, re-run the
# architect manually under `docker run` with the same volumes — same
# image, scratch volumes, scratch network — but with the stub mounted
# and stdin from /dev/null so bash -l exits and the run command finishes.

# Pre-existing architect-workspace volume already has /work cloned from
# Phase 3; we leave that in place so the entrypoint exercises the
# `git -C /work pull --ff-only` path on restart (the on-disk handover
# arrives only after we ran the onboarder, post-Phase-3).
arch_run_out="${work_dir}/architect-restart.out"
arch_run_rc_file="${work_dir}/architect-restart.rc"

# Remove the now-stopped architect container so we can re-create it with
# the additional stub mount. (docker run --rm with the same name would
# collide.)
docker rm -f "${project}-architect" >/dev/null 2>&1 || true

docker run --rm \
    --name "${project}-architect" \
    --network "${network}" \
    -v "${vol_arch_workspace}:/work" \
    -v "${vol_arch_auditor_clone}:/auditor" \
    -v "${vol_arch}:/home/agent/.claude" \
    -v "${repo_root}/methodology:/methodology:ro" \
    -v "${keys_dir}/architect:/home/agent/.ssh:ro" \
    -v "${stub_dir}/architect-claude:/usr/local/bin/claude:ro" \
    -i \
    agent-architect:latest </dev/null \
    >"${arch_run_out}" 2>&1
arch_rc=$?
echo "${arch_rc}" > "${arch_run_rc_file}"

if [ "${arch_rc}" -eq 0 ]; then
    pass "architect entrypoint completed (exit 0) on restart with handover present"
else
    fail "architect entrypoint exited ${arch_rc} on restart"
    note "architect-restart.out tail:"
    tail -30 "${arch_run_out}" 2>/dev/null | sed 's/^/  /' || true
fi

note "architect-restart.out tail:"
tail -25 "${arch_run_out}" 2>/dev/null | sed 's/^/  /' || true

if grep -qF "Onboarding handover detected" "${arch_run_out}"; then
    pass "architect entrypoint logged 'Onboarding handover detected' (Option α fired)"
else
    fail "architect entrypoint did NOT detect the handover on restart"
fi

if grep -qF "Architect bootstrap session ended" "${arch_run_out}"; then
    pass "architect entrypoint logged 'Architect bootstrap session ended' (claude returned, dropped to shell)"
else
    fail "architect entrypoint did not log the bootstrap-ended banner"
fi

# Stub claude marker check.
marker_content=$(docker run --rm -v "${vol_arch}:/v:ro" debian:bookworm-slim \
    cat /v/architect-bootstrap-marker 2>/dev/null || true)
if printf '%s' "${marker_content}" | grep -qx 'stub-claude-invoked'; then
    pass "architect stub claude was invoked by the entrypoint"
else
    fail "architect stub claude was NOT invoked (marker missing or unexpected: '${marker_content}')"
fi
if printf '%s' "${marker_content}" | grep -q '^arg1_head=Read /work/briefs/onboarding/handover.md'; then
    pass "architect stub claude received a bootstrap prompt referencing the handover"
else
    fail "architect stub claude did not receive the expected bootstrap prompt (got: '${marker_content}')"
fi

# ---------------------------------------------------------------------------
# Phase 10 — single-shot rejection via ./onboard-project.sh
# ---------------------------------------------------------------------------
hr; echo "Phase 10: ./onboard-project.sh refuses to re-onboard a populated substrate"

# Phase 9 ran the architect as a one-shot docker-run-and-exit invocation;
# the container is now gone. ./onboard-project.sh requires the architect
# to be running, so bring it back up via the scratch compose for Phase 10.
ce up -d architect >/dev/null
for _ in $(seq 1 30); do
    if ce exec -T -u agent architect test -L /work/CLAUDE.md 2>/dev/null; then
        break
    fi
    sleep 1
done

reject_out="${work_dir}/onboard-reject.out"
ARCHITECT_CONTAINER="${project}-architect" \
GIT_SERVER_CONTAINER="${project}-git-server" \
    bash "${repo_root}/onboard-project.sh" "${source_dir}" --type 1 \
    >"${reject_out}" 2>&1
reject_rc=$?

if [ "${reject_rc}" -ne 0 ]; then
    pass "onboard-project.sh exited non-zero (rc=${reject_rc}) on a populated substrate"
else
    fail "onboard-project.sh exited 0 — single-shot enforcement is broken"
fi

if grep -qF "refusing to onboard" "${reject_out}"; then
    pass "onboard-project.sh error mentions 'refusing to onboard'"
else
    fail "onboard-project.sh refusal message did not name 'refusing to onboard' (got tail follows)"
    tail -20 "${reject_out}" 2>/dev/null | sed 's/^/  /' || true
fi

# Note: the rejection path runs before the source import, so main.git
# should still be at 3 commits (initial + import + handover). Verify the
# rejection did NOT leak additional state.
post_reject_count=$(ce exec -T git-server git --git-dir=/srv/git/main.git rev-list --count main | tr -d '\r\n ')
if [ "${post_reject_count}" = "3" ]; then
    pass "rejection left main.git at 3 commits (no state leaked)"
else
    fail "rejection altered main.git commit count: was 3, now ${post_reject_count}"
fi

# ---------------------------------------------------------------------------
# Phase 11 — argparse error paths in ./onboard-project.sh
# ---------------------------------------------------------------------------
hr; echo "Phase 11: ./onboard-project.sh argparse error paths"

# Missing source-path.
out=$(bash "${repo_root}/onboard-project.sh" 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "<source-path> is required"; then
    pass "no-args invocation: rejects with '<source-path> is required'"
else
    fail "no-args invocation did not reject as expected (rc=${rc}, out='${out}')"
fi

# Non-existent source-path.
out=$(bash "${repo_root}/onboard-project.sh" "/tmp/definitely-does-not-exist-${test_pid}" 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "source-path is not a directory"; then
    pass "non-existent source-path: rejects with 'source-path is not a directory'"
else
    fail "non-existent source-path did not reject as expected (rc=${rc})"
fi

# Invalid --type.
out=$(bash "${repo_root}/onboard-project.sh" "${source_dir}" --type 99 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF -- "--type must be 1, 2, 3, 4"; then
    pass "invalid --type: rejects with the expected error"
else
    fail "invalid --type did not reject as expected (rc=${rc})"
fi

# Help.
out=$(bash "${repo_root}/onboard-project.sh" --help 2>&1) ; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -qF "Usage: ./onboard-project.sh"; then
    pass "--help: prints usage and exits 0"
else
    fail "--help did not print usage / exit 0 (rc=${rc})"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hr
echo "Results: ${pass_count} passed, ${fail_count} failed."
if [ "${fail_count}" -gt 0 ]; then
    exit 1
fi
exit 0
