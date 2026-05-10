#!/bin/bash
# Cross-platform setup logic shared by setup-linux.sh and setup-mac.sh.
# Sourced by the platform entry-points after they have done their own
# platform-specific prereq checks. The platform script is responsible for
# choosing/exporting any platform-specific env (e.g. confirming Colima is
# running on macOS) before sourcing this file.
#
# Idempotent: every step here checks current state and acts only if needed.
# Running setup twice in a row is a no-op on the second run.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[setup] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Verify shared prerequisites (the platform script has already verified
#    its own extras like Docker Desktop / Colima).
# ---------------------------------------------------------------------------
check_prereq() {
    command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1"
}

log "Verifying shared prerequisites..."
check_prereq docker
check_prereq git
check_prereq bash
check_prereq openssl
check_prereq ssh-keygen

if ! docker compose version >/dev/null 2>&1; then
    die "missing prerequisite: docker compose v2 plugin (docker-compose-plugin)"
fi
if ! docker info >/dev/null 2>&1; then
    die "docker daemon is not reachable. On Linux, ensure your user is in the 'docker' group (newgrp docker after adding) or that the daemon is running. On macOS, ensure Docker Desktop or Colima is started."
fi

# ---------------------------------------------------------------------------
# 1.5 Substrate-identity gate. The first state-mutation gate in setup —
# everything before this is read-only (prereq checks, the ~/.docker
# ownership preflight); everything below this point may mutate substrate
# state. The gate handles the five-outcome matrix from
# methodology/deployment-docker.md §3.5: fresh install (creates the
# sentinel), ordinary re-setup (proceeds quietly), or any of three
# inconsistent states (fails loudly with diagnostics + recovery options).
# Sets SUBSTRATE_ID and SUBSTRATE_ID_FRESH_INSTALL for downstream code
# (volume creation, generate-keys.sh).
# ---------------------------------------------------------------------------
# shellcheck source=infra/scripts/substrate-identity.sh
. "${repo_root}/infra/scripts/substrate-identity.sh"

if [ "${TURTLE_CORE_DO_ADOPT:-0}" = "1" ]; then
    log "Adopting existing substrate (--adopt-existing-substrate)..."
    substrate_id_adopt
    log "Adoption succeeded — falling through to ordinary setup. The"
    log "subsequent gate will see matching state and proceed; the rest"
    log "of setup will restart the architect via 'compose up -d'."
fi

log "Checking substrate identity..."
substrate_id_gate

# Mark generate-keys.sh's invocation context as setup-mediated so it does
# not have to re-run the full identity check itself.
export TURTLE_CORE_SETUP_AUTHORIZED=1

# ---------------------------------------------------------------------------
# 2. Create directories that should exist.
# ---------------------------------------------------------------------------
log "Ensuring directory layout..."
mkdir -p \
    "${repo_root}/infra/keys/architect" \
    "${repo_root}/infra/keys/planner"   \
    "${repo_root}/infra/keys/coder"     \
    "${repo_root}/infra/keys/auditor"   \
    "${repo_root}/infra/keys/human"     \
    "${repo_root}/briefs"               \
    "${repo_root}/.pairs"
chmod 700 "${repo_root}/.pairs"
chmod 700 "${repo_root}/infra/keys"/*

# ---------------------------------------------------------------------------
# 3. Generate per-role SSH keypairs (idempotent inside the script).
# ---------------------------------------------------------------------------
log "Generating per-role SSH keys (idempotent)..."
bash "${repo_root}/infra/scripts/generate-keys.sh"

# ---------------------------------------------------------------------------
# 4. Ensure the shared external docker network exists. Both the long-lived
#    compose project and ephemeral planner-pair / audit projects join it.
# ---------------------------------------------------------------------------
log "Ensuring docker network 'agent-net' exists..."
if ! docker network inspect agent-net >/dev/null 2>&1; then
    docker network create agent-net >/dev/null
    log "Created docker network 'agent-net'."
else
    log "Docker network 'agent-net' already exists."
fi

log "Ensuring shared docker volumes exist..."
# claude-state-architect is the durable carrier of the substrate identity
# (see deployment-docker.md §3.5). Label it at create time — Docker local
# volumes do not support label updates after creation. claude-state-shared
# is regenerated each verify, so it carries no identity label.
for vol in claude-state-architect claude-state-shared; do
    if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
        if [ "${vol}" = "claude-state-architect" ]; then
            : "${SUBSTRATE_ID:?SUBSTRATE_ID not set — substrate-id gate did not run}"
            docker volume create \
                --label "app.turtle-core.substrate-id=${SUBSTRATE_ID}" \
                "${vol}" >/dev/null
        else
            docker volume create "${vol}" >/dev/null
        fi
        log "Created docker volume '${vol}'."
    fi
done

# ---------------------------------------------------------------------------
# 5. Build images. agent-base must build first because the role Dockerfiles
#    reference 'FROM agent-base'. Compose alone doesn't order non-service
#    builds, so we drive the base build explicitly.
#
# s009: before compose build, render Dockerfile.generated for coder-daemon
# and auditor from the static template plus the selected platform plugins,
# and render the device-passthrough override file when --device was given.
# SUBSTRATE_PLATFORMS / SUBSTRATE_DEVICES were exported by the entrypoint's
# platform_args_finalize call (see infra/scripts/lib/platform-args.sh).
# ---------------------------------------------------------------------------
: "${SUBSTRATE_PLATFORMS:=default}"
: "${SUBSTRATE_DEVICES:=}"

log "Rendering role Dockerfiles for platforms: ${SUBSTRATE_PLATFORMS}..."
"${repo_root}/infra/scripts/render-dockerfile.sh" coder-daemon "${SUBSTRATE_PLATFORMS}"
"${repo_root}/infra/scripts/render-dockerfile.sh" auditor       "${SUBSTRATE_PLATFORMS}"

log "Rendering device-passthrough override (devices=${SUBSTRATE_DEVICES:-none})..."
"${repo_root}/infra/scripts/render-device-override.sh" "${SUBSTRATE_DEVICES}"

log "Building agent-base image..."
docker build -t agent-base:latest "${repo_root}/infra/base"

log "Building role images via docker compose..."
docker compose --profile ephemeral build

# ---------------------------------------------------------------------------
# 5.5 Setup-time verify per platform per role. The image-build phase ran
#     each platform's verify list once already (Dockerfile RUN), so this
#     is a green-tick check that proves the just-built image still
#     exercises the toolchain (and that the verify commands don't depend
#     on /work or git-server, which aren't up yet).
#
#     We bypass each role's ENTRYPOINT (which starts the daemon /
#     clones repos) by running the image directly with bash. Failure
#     aborts setup.
# ---------------------------------------------------------------------------
log "Verifying platform toolchains in role images..."
verify_failed=()
for platform in ${SUBSTRATE_PLATFORMS//,/ }; do
    [ "${platform}" = "default" ] && continue
    yaml_file="${repo_root}/methodology/platforms/${platform}.yaml"
    for role in coder-daemon auditor; do
        image="agent-${role}:latest"
        # Single yq → json call per (platform, role); python prints one
        # cmd per line.
        verify_json=$(docker run --rm \
            -v "${repo_root}/methodology/platforms:/p:ro" \
            mikefarah/yq:4 -o=json ".roles.\"${role}\".verify // []" \
            "/p/${platform}.yaml" 2>/dev/null || echo "[]")
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
                log "  [verify ok] ${platform}/${role}: ${cmd}"
            else
                log "  [verify FAIL] ${platform}/${role}: ${cmd}"
                verify_failed+=("${platform}/${role}: ${cmd}")
            fi
        done <<<"${cmds}"
    done
done
if [ "${#verify_failed[@]}" -gt 0 ]; then
    echo "[setup] FATAL: setup-time verify failed for the following:" >&2
    for entry in "${verify_failed[@]}"; do
        echo "  - ${entry}" >&2
    done
    die "platform verify failures (see above) — fix the platform YAML or the host environment, then re-run setup."
fi

# ---------------------------------------------------------------------------
# 6. Bring up the long-lived services.
# ---------------------------------------------------------------------------
log "Starting long-lived services (git-server, architect)..."
docker compose up -d git-server architect

# Wait for git-server to be ready (sshd accepting connections inside).
log "Waiting for git-server to be ready..."
for _ in $(seq 1 30); do
    if docker compose exec -T git-server pgrep -x sshd >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# 7. Provision claude-code authentication into the architect's volume.
#    Path A (host-copy) if ~/.claude/.credentials.json exists on the host;
#    Path B (in-container login) otherwise. Brief §4.10.
# ---------------------------------------------------------------------------
host_creds="${HOME}/.claude/.credentials.json"
provision_auth() {
    log "Provisioning claude-code authentication..."
    if [ -f "${host_creds}" ]; then
        log "Found host credentials at ${host_creds} — using Path A (host-copy)."
        # Copy file-to-file via a one-shot helper container so the host
        # never has to read the credentials into a shell variable. Also
        # normalise the architect volume's mount-root ownership: when this
        # helper is the first container to mount an empty claude-state-
        # architect, Docker creates /dst as root:root 0755 in the volume,
        # which would persist and prevent claude-code (running as agent)
        # from writing rotated OAuth tokens later. The chown/chmod is
        # idempotent and retroactively repairs Path A architect volumes
        # that pre-date the s006 fix. The Path B architect avoids this
        # bug via the agent-base Dockerfile pre-create.
        docker run --rm \
            -v "${HOME}/.claude:/host-claude:ro" \
            -v claude-state-architect:/dst \
            debian:bookworm-slim \
            sh -c '
                set -e
                chown 1000:1000 /dst
                chmod 0700 /dst
                cp /host-claude/.credentials.json /dst/.credentials.json
                chmod 600 /dst/.credentials.json
                chown 1000:1000 /dst/.credentials.json
            '
        log "Copied claude-code credentials from ${host_creds} into the architect volume."
        log "The architect will run as the same Claude user you are logged in as on this machine."
    else
        log "No claude-code credentials found at ${host_creds} (Path B)."
        log "After setup completes, run:"
        log "    ./attach-architect.sh"
        log "and run 'claude auth login' once. Your credentials will persist in the"
        log "claude-state-architect docker volume across container restarts."
    fi

    # Whether Path A or Path B: propagate whatever auth is in the architect's
    # volume into the shared volume that ephemeral roles inherit. This is a
    # no-op for Path B until the user runs 'claude auth login'; in that case
    # they should re-run ./verify.sh afterwards to refresh.
    #
    # Always normalise the shared volume's mount-root ownership and mode,
    # whether or not creds are present. Same rationale as verify.sh §6:
    # this helper is the first writer to claude-state-shared, and without
    # the chown/chmod the volume's mount root persists as root:root 0755,
    # which breaks claude-code writes from ephemerals. Idempotent and
    # retroactive.
    docker run --rm \
        -v claude-state-architect:/src:ro \
        -v claude-state-shared:/dst \
        debian:bookworm-slim \
        sh -c '
            chown 1000:1000 /dst
            chmod 0700 /dst
            if [ -f /src/.credentials.json ]; then
                cp /src/.credentials.json /dst/.credentials.json
                chmod 600 /dst/.credentials.json
                chown 1000:1000 /dst/.credentials.json
            fi
            # .claude.json carries claude-code config + project state; its
            # presence is what stops planners / coders / auditors from
            # being treated as fresh installs that need OAuth login. See
            # s007 brief 7.a.
            if [ -f /src/.claude.json ]; then
                cp /src/.claude.json /dst/.claude.json
                chmod 600 /dst/.claude.json
                chown 1000:1000 /dst/.claude.json
            fi
        '
}
provision_auth

# ---------------------------------------------------------------------------
# 8. Initialize bare repos (idempotent — init-repos.sh checks before creating).
# ---------------------------------------------------------------------------
log "Initializing bare git repositories (idempotent)..."
docker compose exec -T git-server /srv/init-repos.sh

# ---------------------------------------------------------------------------
# 9. Run verify.sh as a final sanity check.
# ---------------------------------------------------------------------------
log "Running verify.sh as final sanity check..."
if ! bash "${repo_root}/verify.sh"; then
    die "verify.sh failed; setup is incomplete."
fi

# ---------------------------------------------------------------------------
# 9.5 s009: re-emit the device_required warning so it's the LAST thing the
#     human sees before setup completes. Easy to miss in scrollback otherwise
#     (the brief flagged this explicitly).
# ---------------------------------------------------------------------------
if [ -n "${SUBSTRATE_DEVICE_REQUIRED_MISSING:-}" ]; then
    echo
    echo "================================================================================"
    echo "  REMINDER: device_required platform(s) without --device:"
    echo "================================================================================"
    while IFS= read -r entry; do
        [ -z "${entry}" ] && continue
        pname="${entry%%|*}"
        phint="${entry#*|}"
        echo "    - ${pname}: ${phint}"
    done <<<"${SUBSTRATE_DEVICE_REQUIRED_MISSING}"
    echo
    echo "  HIL test/flash/serial-monitor will not work for these platforms until you"
    echo "  add a device. Either run:"
    echo
    echo "      ./setup-linux.sh --add-device=<host-path>"
    echo
    echo "  on the running substrate, or re-run setup with --device=<host-path>."
    echo "================================================================================"
    echo
fi

# ---------------------------------------------------------------------------
# 10. Print next-steps.
# ---------------------------------------------------------------------------
cat <<'EOF'

================================================================================
  Setup complete.
================================================================================

  Long-lived services:    git-server, architect (running)
  Architect access:       ./attach-architect.sh   (or 'docker compose attach architect')
  Verify state:           ./verify.sh
  Commission a planner:   ./commission-pair.sh <section-slug>
  Commission an auditor:  ./audit.sh <section-slug>

  First steps for the human:
    1. ./attach-architect.sh
    2. Inside the architect:
         Path A — host-creds were pre-loaded; just run 'claude' and you
                  are logged in.
         Path B — run 'claude auth login' once. Then detach (Ctrl-P
                  Ctrl-Q) and run './verify.sh' on the host to
                  propagate credentials into the shared volume.
                  Skipping this step leaves planners / coders /
                  auditors un-authed — every commission will fail.
    3. With the architect, draft TOP-LEVEL-PLAN.md and the first section brief.
    4. Commit those to main; the architect's git-server hook allows it.
    5. Exit the architect; run ./commission-pair.sh <section-slug> to start work.

  See README.md for full documentation, including troubleshooting and the
  refresh procedure for ephemeral-role credentials after the architect's
  OAuth access token rotates.

================================================================================
EOF
