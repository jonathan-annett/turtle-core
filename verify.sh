#!/bin/bash
# verify.sh — substrate smoke test.
# Run after setup, or any time you want to confirm the substrate is healthy.
# Returns 0 on success, non-zero with diagnostics on failure.
#
# This script ALSO refreshes the shared-creds volume (architect → ephemerals)
# so it doubles as the "re-sync after architect refreshed its OAuth token"
# helper described in README.md / brief §4.10.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

ok=0
fail=0

pass() { printf '  [ok] %s\n' "$*"; ok=$((ok+1)); }
flunk() { printf '  [!!] %s\n' "$*" >&2; fail=$((fail+1)); }

echo "verify.sh — substrate smoke test"
echo

# 1. agent-net exists.
if docker network inspect agent-net >/dev/null 2>&1; then
    pass "docker network 'agent-net' exists"
else
    flunk "docker network 'agent-net' is missing — run setup-linux.sh / setup-mac.sh"
fi

# 2. git-server and architect are running.
gs_state=$(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="git-server"{print $2}')
if [ "${gs_state}" = "running" ]; then
    pass "git-server is running"
else
    flunk "git-server is not running (state='${gs_state}')"
fi

ar_state=$(docker compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | awk '$1=="architect"{print $2}')
if [ "${ar_state}" = "running" ]; then
    pass "architect is running"
else
    flunk "architect is not running (state='${ar_state}')"
fi

# 3. Bare repos exist.
if docker compose exec -T git-server test -d /srv/git/main.git/objects 2>/dev/null; then
    pass "main.git bare repo exists in git-server"
else
    flunk "main.git bare repo missing in git-server"
fi
if docker compose exec -T git-server test -d /srv/git/auditor.git/objects 2>/dev/null; then
    pass "auditor.git bare repo exists in git-server"
else
    flunk "auditor.git bare repo missing in git-server"
fi

# 4. Architect can reach git-server over ssh (smoke test: ls-remote main).
if docker compose exec -T -u agent architect bash -lc \
    "git ls-remote git@git-server:/srv/git/main.git >/dev/null 2>&1"; then
    pass "architect can reach git-server over ssh"
else
    flunk "architect cannot reach git-server over ssh — check infra/keys/architect/"
fi

# 5. Both claude-state volumes exist.
for vol in claude-state-architect claude-state-shared; do
    # Compose qualifies named volumes by project name; default is the dir basename.
    fullvol=$(docker volume ls --format '{{.Name}}' | grep -E "(^|_)${vol}\$" | head -1 || true)
    if [ -n "${fullvol}" ]; then
        pass "named volume '${vol}' exists (as '${fullvol}')"
    else
        flunk "named volume '${vol}' is missing"
    fi
done

# 6. Refresh shared creds (architect → ephemerals). Idempotent.
if docker run --rm \
    -v claude-state-architect:/src:ro \
    -v claude-state-shared:/dst \
    debian:bookworm-slim \
    sh -c '
        if [ -f /src/.credentials.json ]; then
            cp /src/.credentials.json /dst/.credentials.json
            chmod 600 /dst/.credentials.json
            chown 1000:1000 /dst/.credentials.json
            exit 0
        fi
        exit 99
    ' >/dev/null 2>&1
then
    pass "architect creds present and synced into shared volume"
else
    rc=$?
    if [ "${rc}" -eq 99 ]; then
        echo "  [..] architect's .credentials.json not yet present."
        echo "        Path B: run './attach-architect.sh' then 'claude auth login'"
        echo "        once, then re-run './verify.sh' to refresh ephemerals."
    else
        flunk "shared-creds refresh failed (rc=${rc})"
    fi
fi

# 7. claude-code is installed in the architect.
if docker compose exec -T -u agent architect which claude >/dev/null 2>&1; then
    pass "claude-code is installed in architect"
else
    flunk "claude-code is not installed in architect — image build may have failed"
fi

echo
echo "Summary: ${ok} ok, ${fail} failed"

if [ "${fail}" -gt 0 ]; then
    exit 1
fi
exit 0
