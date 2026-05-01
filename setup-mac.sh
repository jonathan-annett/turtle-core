#!/bin/bash
# macOS entry-point for substrate setup. Verifies Docker Desktop or Colima
# is running, then delegates to setup-common.sh.
#
# NOTE: This script has not been executed on macOS during template
# development (the author is on Linux). Behavior on macOS is the same as
# on Linux modulo the Docker-runtime check below; named volumes are used
# everywhere to avoid the host↔VM I/O slowdown described in
# methodology/agent-orchestration-spec.md §3.4 and deployment-docker.md §7.2.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "setup-mac.sh: this script is for macOS. Use setup-linux.sh on Linux." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect a running Docker runtime. Docker Desktop OR Colima both work.
# ---------------------------------------------------------------------------
runtime_ok=0
if docker info >/dev/null 2>&1; then
    runtime_ok=1
fi

if [ "${runtime_ok}" -ne 1 ]; then
    cat >&2 <<'EOF'
Docker is not reachable.

You need ONE of:
  (a) Docker Desktop running. Open it from /Applications and wait for
      "Docker Desktop is running" before re-running this script.
  (b) Colima started:
          colima start --cpu 4 --memory 8

Either way, allocate at least 4 CPUs and 8 GB RAM to the Docker VM.
EOF
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "setup-mac.sh: openssl not found (it ships with macOS; check PATH)." >&2
    exit 1
fi

# Source the cross-platform body.
# shellcheck source=setup-common.sh
. "${repo_root}/setup-common.sh"
