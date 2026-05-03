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
# Argument parsing. Recognised flags:
#   --install-docker    Run install-docker.sh and exit.
# ---------------------------------------------------------------------------
do_install_docker=0
for arg in "$@"; do
    case "$arg" in
        --install-docker) do_install_docker=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: ./setup-mac.sh [--install-docker]

  --install-docker   Run install-docker.sh and exit. Use this once on a
                     fresh host to provision Colima + the Docker CLI
                     (via Homebrew), then re-run ./setup-mac.sh (with no
                     arguments) to do the actual substrate setup.

  Without --install-docker, setup verifies your prerequisites and brings
  up the substrate. It does not install or remove anything system-wide.
EOF
            exit 0 ;;
        *)
            echo "setup-mac.sh: unknown argument: $arg" >&2
            echo "Try: ./setup-mac.sh --help" >&2
            exit 2 ;;
    esac
done

# --install-docker is a bootstrap-only mode: provision Docker and exit.
# Re-run without the flag to do the actual substrate setup.
if [ "${do_install_docker}" -eq 1 ]; then
    if [ ! -x "${repo_root}/install-docker.sh" ]; then
        echo "setup-mac.sh: install-docker.sh not found or not executable at ${repo_root}/install-docker.sh" >&2
        exit 1
    fi
    exec "${repo_root}/install-docker.sh"
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

  Quick path: re-run with --install-docker to install and start
  Colima automatically (Homebrew required):

      ./setup-mac.sh --install-docker

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
