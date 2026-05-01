#!/bin/bash
# commission-pair.sh <section-slug>
#
# Starts a coder-daemon and planner pair for a given section, with a per-pair
# random port and bearer token. Pair runs in its own compose project namespace
# so multiple pairs can coexist. On planner exit (any cause) the daemon is
# torn down via 'compose down -v' and the env file removed.
#
# Brief §4.3 + deployment-doc §3.4.

set -euo pipefail

if [ "$#" -ne 1 ] || [ -z "${1:-}" ]; then
    cat >&2 <<'EOF'
Usage: ./commission-pair.sh <section-slug>

Example:
    ./commission-pair.sh s001-hello-timestamps

The section brief must already be committed at briefs/<section-slug>/section.brief.md
on main. The architect produces and commits it before you commission a planner.
EOF
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

section="$1"
project_base="$(basename "${repo_root}")"
project="${project_base}-${section}"

env_file="${repo_root}/.pairs/.pair-${section}.env"
mkdir -p "${repo_root}/.pairs"
chmod 700 "${repo_root}/.pairs"

# ---------------------------------------------------------------------------
# Generate per-pair random port + token. Token is base64 → URL-safe form.
# ---------------------------------------------------------------------------
port=$(awk -v min=10000 -v max=65535 'BEGIN{srand();print int(min+rand()*(max-min+1))}')
token=$(openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-43)

umask 077
cat > "${env_file}" <<EOF
COMMISSION_HOST=coder-daemon
COMMISSION_PORT=${port}
COMMISSION_TOKEN=${token}
EOF

cleanup() {
    echo
    echo "Tearing down pair (project=${project})..."
    docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral down -v --remove-orphans 2>&1 | sed 's/^/  /' || true
    rm -f "${env_file}"
    echo "Pair tear-down complete."
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Bring up the daemon (background). It binds to its compose-network IP and
# waits for commissions from the planner.
# ---------------------------------------------------------------------------
echo "Starting coder-daemon for section '${section}' (project=${project})..."
docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral up -d coder-daemon

brief_path="briefs/${section}/section.brief.md"

cat <<EOF

================================================================================
  Planner commissioning summary  (relay this to the planner)
================================================================================

  Section:        ${section}
  Brief path:     ${brief_path}
  Daemon URL:     http://coder-daemon:${port}
  Bearer token:   (in your environment as \$COMMISSION_TOKEN)

  Paste this into the planner at startup:

      Read /work/${brief_path}. The coder daemon is at
      http://coder-daemon:${port}. Your bearer token is in
      \$COMMISSION_TOKEN. Discharge when the section is done.

================================================================================
EOF

# ---------------------------------------------------------------------------
# Bring up the planner in the foreground. This script blocks until the
# planner exits (or is killed); cleanup() runs the teardown.
# ---------------------------------------------------------------------------
echo "Starting planner (foreground)..."
docker compose -p "${project}" --env-file "${env_file}" --profile ephemeral run --rm planner
