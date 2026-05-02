#!/bin/bash
# Linux entry-point for substrate setup. Also handles ChromeOS Crostini.
# Delegates the cross-platform work to setup-common.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# ---------------------------------------------------------------------------
# ~/.docker ownership preflight. A prior 'sudo docker' (or any other
# root-context docker invocation) leaves ~/.docker owned by root, which
# breaks subsequent non-sudo docker calls in cryptic ways. Fail fast with
# the exact remediation command rather than auto-fixing — the directory
# may legitimately be shared, and surfacing the user-facing decision is
# safer than silently chowning.
# ---------------------------------------------------------------------------
if [ -d "$HOME/.docker" ] && [ "$(stat -c %U "$HOME/.docker")" != "$USER" ]; then
    cat >&2 <<EOF
[setup] FATAL: ~/.docker is owned by '$(stat -c %U "$HOME/.docker")', not '$USER'.
        This is almost always caused by a prior 'sudo docker' invocation
        creating the directory as root. Subsequent non-sudo docker calls
        will fail in cryptic ways.

        Fix it:
            sudo chown -R "\$USER:\$USER" ~/.docker

        Then re-run this script.
EOF
    exit 1
fi

# ---------------------------------------------------------------------------
# Crostini detection — ChromeOS Linux (Crostini) presents as Debian inside
# the Termina VM. From Docker's perspective it is just Linux, so we proceed
# with the Linux path, but advise the user about the resource quirks.
# ---------------------------------------------------------------------------
is_crostini() {
    [ -f /dev/.cros_milestone ] && return 0
    if [ -r /etc/os-release ]; then
        # ChromeOS containers conventionally have hostname 'penguin' and
        # /etc/os-release that mentions Debian. Best-effort heuristic.
        local hn
        hn=$(hostname 2>/dev/null || echo)
        [ "${hn}" = "penguin" ] && return 0
    fi
    return 1
}

if is_crostini; then
    cat <<'EOF'

================================================================================
  Detected ChromeOS / Crostini.
================================================================================

  The substrate works on Crostini, but please confirm:

  1. Docker Engine (docker-ce, installed via apt) — NOT Docker Desktop.
     Docker Desktop on Crostini is unreliable due to nested virtualization.

  2. Linux VM resources allocated via ChromeOS Settings > Linux > "Disk size":
       - At least 8 GB RAM
       - At least 16 GB disk

  3. Performance note: nested-VM I/O is slower than native Linux. Expect
     ephemeral container spawn times of several seconds.

  Continuing with Linux setup. Press Ctrl-C to abort if any of the above
  is not yet in place.

================================================================================

EOF
fi

# ---------------------------------------------------------------------------
# Linux-specific prereq verification (the rest is in setup-common.sh).
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
    cat >&2 <<'EOF'
docker is not installed. On Debian/Ubuntu/Crostini:
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    newgrp docker
EOF
    exit 1
fi

# Source the cross-platform body.
# shellcheck source=setup-common.sh
. "${repo_root}/setup-common.sh"
