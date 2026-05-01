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
for vol in claude-state-architect claude-state-shared; do
    if ! docker volume inspect "${vol}" >/dev/null 2>&1; then
        docker volume create "${vol}" >/dev/null
        log "Created docker volume '${vol}'."
    fi
done

# ---------------------------------------------------------------------------
# 5. Build images. agent-base must build first because the role Dockerfiles
#    reference 'FROM agent-base'. Compose alone doesn't order non-service
#    builds, so we drive the base build explicitly.
# ---------------------------------------------------------------------------
log "Building agent-base image..."
docker build -t agent-base:latest "${repo_root}/infra/base"

log "Building role images via docker compose..."
docker compose --profile ephemeral build

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
        # never has to read the credentials into a shell variable.
        docker run --rm \
            -v "${HOME}/.claude:/host-claude:ro" \
            -v claude-state-architect:/dst \
            debian:bookworm-slim \
            sh -c '
                set -e
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
    docker run --rm \
        -v claude-state-architect:/src:ro \
        -v claude-state-shared:/dst \
        debian:bookworm-slim \
        sh -c '
            if [ -f /src/.credentials.json ]; then
                cp /src/.credentials.json /dst/.credentials.json
                chmod 600 /dst/.credentials.json
                chown 1000:1000 /dst/.credentials.json
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
    2. Inside the architect: 'claude' (or 'claude auth login' first if Path B)
    3. With the architect, draft TOP-LEVEL-PLAN.md and the first section brief.
    4. Commit those to main; the architect's git-server hook allows it.
    5. Exit the architect; run ./commission-pair.sh <section-slug> to start work.

  See README.md for full documentation, including troubleshooting and the
  refresh procedure for ephemeral-role credentials after the architect's
  OAuth access token rotates.

================================================================================
EOF
