#!/bin/bash
# test-code-migration.sh — infrastructure test for s014 Section B (code
# migration agent).
#
# Scaffolds an isolated scratch substrate (parallel to s012's
# test-onboarder-shell.sh), drives infra/scripts/dispatch-code-migration.sh
# against the code-migration-smoke fixture with a stub claude, and
# verifies the new plumbing end-to-end:
#
#   - infra/scripts/infer-platforms.sh detects python-extras from the
#     fixture's requirements.txt + pyproject.toml signals.
#   - infra/scripts/compose-image.sh code-migration produces a
#     hash-tagged image for the declared platform set (python-extras).
#   - infra/scripts/validate-tool-surface.sh passes for the
#     code-migration brief's tool surface against the composed image
#     (F52 closure — the python-extras code-migration role block
#     installs ruff/mypy/pip into the venv on PATH).
#   - infra/scripts/dispatch-code-migration.sh, given a properly-formed
#     migration brief on main and a stub claude that writes the
#     six-section report, runs the agent and the report ends up on
#     main at the canonical path.
#   - The git-server's update hook rejects code-migration pushes to
#     any path other than briefs/onboarding/code-migration.report.md
#     (path-restriction defence in depth).
#
# Real claude-code execution is NOT exercised — the test injects a stub
# `claude` binary into the code-migration image via a per-`compose run`
# volume mount. The stub handles `-p` mode invocation (F56 generalisation):
# the real claude is invoked as `claude -p "<prompt>" ...` so $1 is `-p`;
# the stub ignores all args and just writes the report.
#
# Required: agent-{base,onboarder,code-migration,git-server} images
# already built on the host (`./setup-linux.sh` or `./setup-mac.sh`
# will build them; the code-migration image is new in s014 so a stale
# pre-s014 setup will not have it — re-run setup after merging s014).
#
# Run:
#   bash infra/scripts/tests/test-code-migration.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
test_pid=$$
project="turtle-core-test-s014-${test_pid}"
network="${project}-net"

vol_shared="${project}-claude-state-shared"
vol_main_bare="${project}-main-bare"
vol_auditor_bare="${project}-auditor-bare"

work_dir="/tmp/${project}"
keys_dir="${work_dir}/keys"
fixture_dir="${repo_root}/infra/scripts/tests/fixtures/code-migration-smoke"
stub_dir="${work_dir}/stub"
compose_file="${work_dir}/docker-compose.yml"

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
    if [ -f "${compose_file}" ]; then
        docker compose -p "${project}" -f "${compose_file}" \
            --profile ephemeral down --remove-orphans >/dev/null 2>&1 || true
    fi
    docker volume rm \
        "${vol_shared}" "${vol_main_bare}" "${vol_auditor_bare}" \
        >/dev/null 2>&1 || true
    docker network rm "${network}" >/dev/null 2>&1 || true
    rm -rf "${work_dir}" 2>/dev/null || true
    exit "${rc}"
}
trap cleanup_test EXIT INT TERM

ce() {
    docker compose -p "${project}" -f "${compose_file}" "$@"
}

# ===========================================================================
# Phase 0 — prereqs
# ===========================================================================
hr; echo "Phase 0: prereqs"

req_imgs=(agent-base agent-code-migration agent-git-server)
missing=0
for img in "${req_imgs[@]}"; do
    if ! docker image inspect "${img}:latest" >/dev/null 2>&1; then
        fail "image '${img}:latest' is missing — run setup-linux.sh / setup-mac.sh first"
        missing=1
    fi
done
if [ "${missing}" -eq 0 ]; then
    pass "all required images present"
else
    note "stopping: cannot exercise the code-migration agent without its image"
    exit 1
fi

if [ ! -d "${fixture_dir}" ]; then
    fail "fixture directory missing: ${fixture_dir}"
    exit 1
fi
pass "smoke fixture present at ${fixture_dir}"

# ===========================================================================
# Phase 1 — unit: infer-platforms.sh against the smoke fixture
# ===========================================================================
hr; echo "Phase 1: infer-platforms.sh signal detection"

inferred=$("${repo_root}/infra/scripts/infer-platforms.sh" "${fixture_dir}")
if [ "${inferred}" = "python-extras" ]; then
    pass "infer-platforms.sh detected exactly 'python-extras' from the fixture"
else
    fail "infer-platforms.sh produced '${inferred}' (expected 'python-extras')"
fi

# Negative case: empty source dir.
empty_dir="${work_dir}/empty-infer-check"
mkdir -p "${empty_dir}"
inferred_empty=$("${repo_root}/infra/scripts/infer-platforms.sh" "${empty_dir}")
if [ -z "${inferred_empty}" ]; then
    pass "infer-platforms.sh emits empty for a source with no signal files"
else
    fail "infer-platforms.sh produced '${inferred_empty}' for empty source (expected empty)"
fi

# Polyglot inference: requirements.txt + package.json → python-extras,node-extras.
poly_dir="${work_dir}/poly-infer-check"
mkdir -p "${poly_dir}"
touch "${poly_dir}/requirements.txt" "${poly_dir}/package.json"
inferred_poly=$("${repo_root}/infra/scripts/infer-platforms.sh" "${poly_dir}")
case "${inferred_poly}" in
    "node-extras,python-extras"|"python-extras,node-extras")
        pass "infer-platforms.sh detects both python-extras and node-extras when both signals present"
        ;;
    *)
        fail "infer-platforms.sh polyglot detection produced '${inferred_poly}' (expected python-extras,node-extras in either order)"
        ;;
esac

# ===========================================================================
# Phase 2 — unit: compose-image.sh produces a hash-tagged image
# ===========================================================================
hr; echo "Phase 2: compose-image.sh code-migration python-extras"

if ! image_tag=$("${repo_root}/infra/scripts/compose-image.sh" code-migration python-extras 2>"${work_dir}/compose.err"); then
    fail "compose-image.sh failed for code-migration / python-extras"
    note "stderr:"
    sed 's/^/  /' "${work_dir}/compose.err" || true
    exit 1
fi

case "${image_tag}" in
    agent-code-migration-platforms:*)
        pass "compose-image.sh produced expected tag namespace (${image_tag})"
        ;;
    *)
        fail "compose-image.sh produced unexpected tag '${image_tag}' (expected agent-code-migration-platforms:*)"
        ;;
esac

# Recompose with the same args — should be a cache hit (same tag).
image_tag_again=$("${repo_root}/infra/scripts/compose-image.sh" code-migration python-extras 2>/dev/null)
if [ "${image_tag}" = "${image_tag_again}" ]; then
    pass "compose-image.sh re-emit produced the same tag (cache hit on identical inputs)"
else
    fail "compose-image.sh re-emit produced a different tag (cache invalidation when it should have hit)"
fi

# Empty platform set produces a DIFFERENT (or no-platforms) hash.
image_tag_empty=$("${repo_root}/infra/scripts/compose-image.sh" code-migration "" 2>/dev/null)
case "${image_tag_empty}" in
    agent-code-migration-platforms:*)
        if [ "${image_tag_empty}" != "${image_tag}" ]; then
            pass "compose-image.sh empty set produces a distinct tag from python-extras"
        else
            fail "compose-image.sh empty set produced the same tag as python-extras (hash collision)"
        fi
        ;;
    *)
        fail "compose-image.sh empty set produced unexpected tag '${image_tag_empty}'"
        ;;
esac

# Verify the python-extras image actually has ruff/mypy/pip on PATH —
# this is the python-extras YAML's code-migration role block.
for binary in ruff mypy pip python3; do
    if docker run --rm --entrypoint bash "${image_tag}" -c "command -v ${binary}" >/dev/null 2>&1; then
        pass "composed image has '${binary}' on PATH (python-extras code-migration role block landed)"
    else
        fail "composed image lacks '${binary}' on PATH — python-extras code-migration role block may not have rendered correctly"
    fi
done

# ===========================================================================
# Phase 3 — unit: validate-tool-surface.sh against the composed image
# ===========================================================================
hr; echo "Phase 3: validate-tool-surface.sh against composed code-migration image"

tool_surface="Read,Edit,Write,Bash(pip:*),Bash(ruff:*),Bash(mypy:*),Bash(python3:*),Bash(git add:*),Bash(git commit:*),Bash(git push:*),Bash(grep:*),Bash(find:*)"
if "${repo_root}/infra/scripts/validate-tool-surface.sh" "${image_tag}" "${tool_surface}" python-extras >/dev/null 2>"${work_dir}/validate.err"; then
    pass "validate-tool-surface.sh passes for python-extras agent's tool surface"
else
    fail "validate-tool-surface.sh failed for the composed image's expected tool surface (F52 closure broken)"
    note "stderr:"
    sed 's/^/  /' "${work_dir}/validate.err" || true
fi

# Negative case: a tool surface that names a missing binary should fail.
bad_surface="${tool_surface},Bash(nonexistent-binary-xyzzy:*)"
if "${repo_root}/infra/scripts/validate-tool-surface.sh" "${image_tag}" "${bad_surface}" python-extras >/dev/null 2>&1; then
    fail "validate-tool-surface.sh accepted a tool surface naming a missing binary (F52 closure not enforcing)"
else
    pass "validate-tool-surface.sh rejects a tool surface naming a missing binary"
fi

# ===========================================================================
# Phase 4 — scaffold scratch substrate (git-server only; the test
# exercises dispatch-code-migration.sh's flow without bringing the
# architect up — we use a placeholder architect-style git clone to
# simulate the brief-on-main state).
# ===========================================================================
hr; echo "Phase 4: scaffold scratch substrate"

mkdir -p "${keys_dir}"/{human,onboarder,code-migration}
chmod 700 "${keys_dir}"
chmod 700 "${keys_dir}"/*
for role in human onboarder code-migration; do
    ssh-keygen -t ed25519 -N '' -C "${role}@${project}" \
        -f "${keys_dir}/${role}/id_ed25519" -q >/dev/null 2>&1
    chmod 600 "${keys_dir}/${role}/id_ed25519"
done
pass "generated scratch ssh keys (human, onboarder, code-migration)"

docker network create "${network}" >/dev/null
pass "created scratch network '${network}'"

for vol in "${vol_shared}" "${vol_main_bare}" "${vol_auditor_bare}"; do
    docker volume create "${vol}" >/dev/null
done
docker run --rm -v "${vol_shared}:/v" debian:bookworm-slim \
    sh -c 'chown 1000:1000 /v && chmod 0700 /v && echo "{}" > /v/.claude.json && chown 1000:1000 /v/.claude.json && chmod 600 /v/.claude.json' \
    >/dev/null
pass "created scratch volumes (mount-roots normalised; .claude.json seeded)"

cat > "${compose_file}" <<COMPOSE_EOF
# Generated for code-migration test (pid ${test_pid}).
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

  code-migration:
    image: agent-code-migration:latest
    profiles: ["ephemeral"]
    environment:
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY:-}
    volumes:
      - ${vol_shared}:/home/agent/.claude
      - ${repo_root}/methodology:/methodology:ro
      - ${keys_dir}/code-migration:/home/agent/.ssh:ro
      - \${SOURCE_PATH:-/dev/null}:/source:ro
      - ${repo_root}/infra/scripts/lib/parse-tool-surface.sh:/usr/local/lib/turtle-core/parse-tool-surface.sh:ro
    networks: [agent-net]
    stdin_open: true
    tty: true

volumes:
  ${vol_main_bare}:
    external: true
  ${vol_auditor_bare}:
    external: true
  ${vol_shared}:
    external: true

networks:
  agent-net:
    external: true
    name: ${network}
COMPOSE_EOF
pass "wrote scratch compose file"

# ===========================================================================
# Phase 5 — bring up git-server, init bare repos, seed import commit
# ===========================================================================
hr; echo "Phase 5: scratch git-server + bare repos + source import"

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

# Verify the git-server's authorized_keys recognises the code-migration role
# (s014 B.4 added it). The entrypoint logs each role it loads a key for.
if ce logs git-server 2>&1 | grep -q 'Authorized key loaded for role: code-migration'; then
    pass "git-server entrypoint loaded the code-migration key (s014 B.4)"
else
    fail "git-server did not log code-migration key load — entrypoint roles list may be missing 'code-migration'"
fi

# Seed main.git with the source-import commit (so the migration brief
# can land on top of it; same pattern ./onboard-project.sh follows).
if docker run --rm \
        -v "${keys_dir}/onboarder:/k:ro" \
        -v "${fixture_dir}:/src:ro" \
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
            chown -R root:root .
            git -c user.email=onboarder@substrate.local -c user.name=onboarder add -A
            git -c user.email=onboarder@substrate.local -c user.name=onboarder commit -q -m "onboarding: import source materials"
            git -c user.email=onboarder@substrate.local -c user.name=onboarder push -q origin main
        ' >/dev/null 2>&1; then
    pass "source import push succeeded"
else
    fail "source import push failed"
    exit 1
fi

# ===========================================================================
# Phase 6 — author the migration brief and push it (simulates onboarder
# phase 1 having committed the brief; we skip the onboarder for this
# plumbing test and write the brief directly).
# ===========================================================================
hr; echo "Phase 6: migration brief authored and pushed to main"

brief_md="${work_dir}/code-migration.brief.md"
cat > "${brief_md}" <<'BRIEF_EOF'
# Code Migration Brief — code-migration-smoke fixture

This is a code-migration commissioning brief authored by the onboarder
test harness. Restate this objective in your own words at the top of
your report under the **Brief echo** heading.

## Objective

Perform a structural review of the source materials at `/source` and produce a migration report at `/work/briefs/onboarding/code-migration.report.md`. Structural review only — no behavioural test execution, no build verification beyond what the tool surface explicitly grants for survey purposes.

## Available context

- `/source` — read-only mount of the brownfield materials.
- `/methodology/code-migration-agent-guide.md` — your role guide.
- `/methodology/code-migration-report-template.md` — the report shape.
- Project type hint: 1 (code only).

## Required platforms

```yaml
- python-extras
```

## Required tool surface

```yaml
- Read
- Edit
- Write
- Bash(pip:*)
- Bash(ruff:*)
- Bash(mypy:*)
- Bash(python3:*)
- Bash(grep:*)
- Bash(find:*)
- Bash(git add:*)
- Bash(git commit:*)
- Bash(git push:*)
```

## Output destination

Commit and push the migration report to `briefs/onboarding/code-migration.report.md` on `main`. Your role identity allows pushes to `refs/heads/main` only when the changed paths are exactly that one file. Commit with the message `onboarding: code-migration report` exactly.

## Reporting requirements

Per `/methodology/code-migration-report-template.md`: six sections with exact heading wording (Brief echo / Per-component intent / Structural completeness / Findings / Operational notes / Open questions). Severity legend HIGH / LOW / INFO, framed for-architect's-attention.
BRIEF_EOF
pass "wrote scratch migration brief at ${brief_md}"

# Push the brief on top of the import commit using the onboarder
# identity.
if docker run --rm \
        -v "${keys_dir}/onboarder:/k:ro" \
        -v "${brief_md}:/brief.md:ro" \
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
            mkdir -p briefs/onboarding
            cp /brief.md briefs/onboarding/code-migration.brief.md
            git -c user.email=onboarder@substrate.local -c user.name=onboarder add briefs/onboarding/code-migration.brief.md
            git -c user.email=onboarder@substrate.local -c user.name=onboarder commit -q -m "onboarding: code-migration brief"
            git -c user.email=onboarder@substrate.local -c user.name=onboarder push -q origin main
        ' >/dev/null 2>&1; then
    pass "migration brief pushed to main"
else
    fail "migration brief push failed"
    exit 1
fi

# ===========================================================================
# Phase 7 — stub claude for the code-migration agent, run the agent
# via docker compose run (mirroring dispatch-code-migration.sh's
# invocation; we don't invoke the dispatch helper here because it does
# a check-brief-exists against the architect container, which we are
# not running for this narrow test — Phase 8 separately covers the
# dispatch helper's argparse and brief-check paths).
# ===========================================================================
hr; echo "Phase 7: code-migration agent run with stub claude"

mkdir -p "${stub_dir}"
cat > "${stub_dir}/code-migration-claude" <<'STUB_EOF'
#!/bin/bash
# Stub claude for the s014 code-migration plumbing test.
#
# The real entrypoint invokes claude as:
#   claude -p "<prompt>" --permission-mode dontAsk --allowed-tools "<tools>"
# F56 generalisation: $1 may be `-p` or the prompt itself depending on
# invocation shape. This stub ignores all args and just writes the
# six-section report, commits, and pushes. Exits 0.
set -euo pipefail
cd /work
mkdir -p briefs/onboarding
cat > briefs/onboarding/code-migration.report.md <<'REPORT_EOF'
# Code migration report — code-migration-smoke fixture (test stub)

Generated by test-code-migration.sh's stub claude. Verifies the
code-migration container's entrypoint, key plumbing, and git-server
hook all line up end-to-end for the report-commit path.

## 1. Brief echo

I understood the task to be a structural review of /source per
methodology/code-migration-agent-guide.md, producing this six-section
report. Platforms: python-extras.

## 2. Per-component intent

- `smoke/` — Python package, **Active** (Confirmed: imports closed for main → greeting).
- `smoke/orphan.py` — Python module, **Speculative orphan** (Confirmed: no importers in `git grep`).
- `requirements.txt` — pip-readable dependency manifest.
- `pyproject.toml` — PEP 518 build metadata, minimal.

## 3. Structural completeness

- Import graph closes for `main → greeting`.
- `pip install --dry-run -r requirements.txt` fails on `requestz==2.31.0` (line 6).
- One orphan: `smoke/orphan.py` (no importers).

## 4. Findings

### [HIGH] Misspelled dependency `requestz` in requirements.txt

**Location:** `requirements.txt:6`
**Evidence:** `pip install --dry-run` rejects with "No matching distribution found for requestz".
**Suggested next step:** Architect confirms intent — almost certainly `requests`. Stub report; the real agent would have run the probe.

### [LOW] Orphan module smoke/orphan.py

**Location:** `smoke/orphan.py`
**Evidence:** No importers found in `git grep -nE "^(from|import) smoke.orphan"`.
**Suggested next step:** Architect confirms whether this is dead code or kept for a not-yet-documented reason.

## 5. Operational notes

- The fixture is a B.8 stub-claude run; real-claude findings will be
  richer.

## 6. Open questions

- Test fixture only — no real open questions from the stub.
REPORT_EOF

git -c user.email=code-migration@substrate.local -c user.name=code-migration \
    add briefs/onboarding/code-migration.report.md
git -c user.email=code-migration@substrate.local -c user.name=code-migration \
    commit -q -m "onboarding: code-migration report"
git push -q origin main
exit 0
STUB_EOF
chmod 0755 "${stub_dir}/code-migration-claude"

# Build the bootstrap prompt the dispatch helper would have set, then
# run the code-migration service directly via `compose run --rm -T`
# with the stub mounted and BRIEF_PATH set.
bootstrap_prompt="Read /work/briefs/onboarding/code-migration.brief.md, which is your migration brief. Perform structural review per the brief. Produce the migration report at /work/briefs/onboarding/code-migration.report.md. Commit with the exact message 'onboarding: code-migration report', push to origin main, and discharge."

SOURCE_PATH="${fixture_dir}" \
ce run --rm -T \
    -e BOOTSTRAP_PROMPT="${bootstrap_prompt}" \
    -e BRIEF_PATH="/work/briefs/onboarding/code-migration.brief.md" \
    -v "${stub_dir}/code-migration-claude:/usr/local/bin/claude:ro" \
    code-migration </dev/null >"${work_dir}/code-migration.out" 2>&1
code_migration_rc=$?

if [ "${code_migration_rc}" -eq 0 ]; then
    pass "code-migration container ran and exited 0"
else
    fail "code-migration container exited ${code_migration_rc} (expected 0)"
    note "code-migration.out tail:"
    tail -25 "${work_dir}/code-migration.out" 2>/dev/null | sed 's/^/  /' || true
fi

if grep -qF "Bootstrap prompt detected" "${work_dir}/code-migration.out"; then
    pass "code-migration entrypoint logged 'Bootstrap prompt detected' banner"
else
    fail "code-migration entrypoint did not log bootstrap-detected banner"
fi

if grep -qF "Allowed tools: " "${work_dir}/code-migration.out"; then
    pass "code-migration entrypoint parsed and announced tool surface"
else
    fail "code-migration entrypoint did not announce allowed tools (parse-tool-surface.sh failed?)"
fi

# ===========================================================================
# Phase 8 — verify report state on main.git
# ===========================================================================
hr; echo "Phase 8: verify code-migration.report.md on main"

report_blob=$(ce exec -T git-server \
    git --git-dir=/srv/git/main.git show "main:briefs/onboarding/code-migration.report.md" 2>/dev/null)

if [ -n "${report_blob}" ]; then
    pass "code-migration.report.md exists on main and is non-empty"
else
    fail "code-migration.report.md is missing or empty on main"
fi

report_msg=$(ce exec -T git-server git --git-dir=/srv/git/main.git log -1 --format=%s main | tr -d '\r')
if [ "${report_msg}" = "onboarding: code-migration report" ]; then
    pass "report commit subject is 'onboarding: code-migration report'"
else
    fail "report commit subject mismatched (got: '${report_msg}')"
fi

expected_headings=(
    '^## 1\. Brief echo$'
    '^## 2\. Per-component intent$'
    '^## 3\. Structural completeness$'
    '^## 4\. Findings$'
    '^## 5\. Operational notes$'
    '^## 6\. Open questions$'
)
all_present=1
for pattern in "${expected_headings[@]}"; do
    if printf '%s' "${report_blob}" | grep -Eq "${pattern}"; then
        :
    else
        all_present=0
        note "missing heading matching: ${pattern}"
    fi
done
if [ "${all_present}" -eq 1 ]; then
    pass "all 6 migration-report headings present (presence check)"
else
    fail "one or more required headings missing from migration report"
fi

# ===========================================================================
# Phase 9 — git-server hook rejects code-migration pushes to wrong paths
# ===========================================================================
hr; echo "Phase 9: hook rejects code-migration pushes outside the report path"

# Try to push a file at a wrong path under refs/heads/main from the
# code-migration role. Should fail with the hook's diagnostic.
hook_reject_out="${work_dir}/hook-reject.out"
if docker run --rm \
        -v "${keys_dir}/code-migration:/k:ro" \
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
            mkdir -p briefs/onboarding
            echo "smuggled" > briefs/onboarding/smuggled.md
            git -c user.email=code-migration@substrate.local -c user.name=code-migration add briefs/onboarding/smuggled.md
            git -c user.email=code-migration@substrate.local -c user.name=code-migration commit -q -m "attempt push outside the report path"
            git -c user.email=code-migration@substrate.local -c user.name=code-migration push -q origin main
        ' >"${hook_reject_out}" 2>&1; then
    fail "git-server hook ACCEPTED a code-migration push to a non-report path — path restriction broken"
else
    pass "git-server hook rejected code-migration push to a non-report path (rc=$?)"
fi

if grep -qF "code-migration may not modify" "${hook_reject_out}"; then
    pass "hook rejection message names the path-restriction diagnostic"
else
    fail "hook rejection lacked the expected diagnostic (output below)"
    sed 's/^/  /' "${hook_reject_out}" 2>/dev/null || true
fi

# Try a wrong-ref push (e.g. refs/heads/main-shadow). Should also fail.
hook_ref_reject_out="${work_dir}/hook-ref-reject.out"
if docker run --rm \
        -v "${keys_dir}/code-migration:/k:ro" \
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
            git checkout -q -b shadow
            echo "wrong-branch" > briefs/onboarding/code-migration.report.md
            git -c user.email=code-migration@substrate.local -c user.name=code-migration add briefs/onboarding/code-migration.report.md
            git -c user.email=code-migration@substrate.local -c user.name=code-migration commit -q -m "wrong-ref push attempt"
            git -c user.email=code-migration@substrate.local -c user.name=code-migration push -q origin shadow
        ' >"${hook_ref_reject_out}" 2>&1; then
    fail "git-server hook ACCEPTED a code-migration push to refs/heads/shadow"
else
    pass "git-server hook rejected code-migration push to a non-main ref"
fi

if grep -qF "code-migration may push only to refs/heads/main" "${hook_ref_reject_out}"; then
    pass "hook ref-rejection message names the expected diagnostic"
else
    note "hook ref-rejection output:"
    sed 's/^/  /' "${hook_ref_reject_out}" 2>/dev/null || true
fi

# ===========================================================================
# Phase 10 — dispatch-code-migration.sh argparse error paths
# ===========================================================================
hr; echo "Phase 10: dispatch-code-migration.sh argparse + error paths"

# --help.
out=$(bash "${repo_root}/infra/scripts/dispatch-code-migration.sh" --help 2>&1) ; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -qF "dispatch-code-migration.sh"; then
    pass "--help prints usage and exits 0"
else
    fail "--help did not print usage / exit 0 (rc=${rc})"
fi

# Unknown flag.
out=$(bash "${repo_root}/infra/scripts/dispatch-code-migration.sh" --bogus 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "unknown flag"; then
    pass "unknown flag rejected"
else
    fail "unknown flag not rejected (rc=${rc})"
fi

# Missing source-path with no SOURCE_PATH env.
unset SOURCE_PATH 2>/dev/null || true
out=$(bash "${repo_root}/infra/scripts/dispatch-code-migration.sh" 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "source path is required"; then
    pass "missing source-path rejected with the expected message"
else
    fail "missing source-path not rejected as expected (rc=${rc})"
fi

# Non-existent source-path.
out=$(bash "${repo_root}/infra/scripts/dispatch-code-migration.sh" --source-path "/tmp/definitely-not-a-dir-${test_pid}" 2>&1) ; rc=$?
if [ "${rc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "not a directory"; then
    pass "non-existent source-path rejected"
else
    fail "non-existent source-path not rejected (rc=${rc})"
fi

# ===========================================================================
# Summary
# ===========================================================================
hr
echo "Results: ${pass_count} passed, ${fail_count} failed."
if [ "${fail_count}" -gt 0 ]; then
    exit 1
fi
exit 0
