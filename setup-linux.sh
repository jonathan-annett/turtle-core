#!/bin/bash
# Linux entry-point for substrate setup. Also handles ChromeOS Crostini.
# Delegates the cross-platform work to setup-common.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

# ---------------------------------------------------------------------------
# Argument parsing. Recognised flags:
#   --install-docker              Run install-docker.sh and exit.
#   --adopt-existing-substrate    One-shot migration: label this host's
#                                 existing claude-state-architect volume
#                                 and write a new .substrate-id sentinel.
#   --platform=<name>[,...]       Build target platform(s) into the role
#                                 images (s009).
#   --device=<host-path>[,...]    Map host device(s) into the role
#                                 containers (s009).
#   --add-platform=<name>         Extend a running substrate's toolchain
#                                 (s009).
#   --add-device=<host-path>[,...]  Extend a running substrate's device
#                                 passthrough list (s009).
#   --force                       Skip --add-* pre-flight checks.
# ---------------------------------------------------------------------------
# shellcheck source=infra/scripts/lib/platform-args.sh
. "${repo_root}/infra/scripts/lib/platform-args.sh"
platform_args_init

do_install_docker=0
do_adopt=0
for arg in "$@"; do
    if platform_args_consume "${arg}"; then
        continue
    fi
    case "$arg" in
        --install-docker) do_install_docker=1 ;;
        --adopt-existing-substrate) do_adopt=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: ./setup-linux.sh [flags...]

  --install-docker   Run install-docker.sh and exit. Use this once on a
                     fresh host to provision Docker Engine + Compose +
                     Buildx, then re-run ./setup-linux.sh (with no
                     arguments) to do the actual substrate setup. The
                     two-shot pattern is required because the docker-group
                     membership the installer adds takes effect only in a
                     new login shell.

  --adopt-existing-substrate
                     One-shot migration for substrates that predate the
                     substrate-identity mechanism. Mints a new UUID,
                     writes it to .substrate-id, and rotates the
                     claude-state-architect docker volume so it carries
                     a matching app.turtle-core.substrate-id label.
                     Requires the architect container to be stoppable
                     (it is briefly stopped during volume rotation, then
                     restarted as setup proceeds normally). Refuses if
                     .substrate-id already exists.

EOF
            platform_args_help_block
            cat <<'EOF'

  Without flags, setup verifies your prerequisites and brings up the
  substrate. It does not install or remove anything system-wide.
EOF
            exit 0 ;;
        *)
            echo "setup-linux.sh: unknown argument: $arg" >&2
            echo "Try: ./setup-linux.sh --help" >&2
            exit 2 ;;
    esac
done

if [ "${do_install_docker}" -eq 1 ] && [ "${do_adopt}" -eq 1 ]; then
    echo "setup-linux.sh: --install-docker and --adopt-existing-substrate are mutually exclusive." >&2
    exit 2
fi

if [ "${do_adopt}" -eq 1 ]; then
    export TURTLE_CORE_DO_ADOPT=1
fi

# --install-docker is bootstrap-only and exits before setup-common.sh is
# sourced; finalize the platform args only when we'll actually run setup.
if [ "${do_install_docker}" -eq 0 ]; then
    platform_args_finalize
fi

# --install-docker is a bootstrap-only mode: provision Docker and exit.
# It deliberately does not continue into the verify/setup path because:
#   1. On Linux, install-docker.sh's group-membership change requires
#      a new login shell before non-sudo docker works.
#   2. The substrate-setup steps (key generation, image build, volume
#      provisioning) are disjoint from system-package installation and
#      should not run as a side effect of bootstrapping the host.
if [ "${do_install_docker}" -eq 1 ]; then
    if [ ! -x "${repo_root}/install-docker.sh" ]; then
        echo "setup-linux.sh: install-docker.sh not found or not executable at ${repo_root}/install-docker.sh" >&2
        exit 1
    fi
    exec "${repo_root}/install-docker.sh"
fi

# s009 9.e: --add-platform / --add-device dispatch a one-shot extension
# of an already-running substrate. Refuse combination with the initial-
# setup --platform / --device flags, which would be ambiguous.
if [ -n "${SUBSTRATE_ADD_PLATFORM:-}" ] || [ -n "${SUBSTRATE_ADD_DEVICES:-}" ]; then
    if [ "${SUBSTRATE_PLATFORM_SUPPLIED:-0}" = "1" ] || [ "${SUBSTRATE_DEVICE_SUPPLIED:-0}" = "1" ]; then
        echo "setup-linux.sh: --add-platform / --add-device cannot be combined with --platform / --device." >&2
        echo "  --platform / --device are for initial substrate setup." >&2
        echo "  --add-platform / --add-device extend a running substrate in place." >&2
        exit 2
    fi
    exec "${repo_root}/infra/scripts/add-platform-device.sh"
fi

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
docker is not installed.

  Quick path: re-run with --install-docker to install Docker Engine,
  Compose, and Buildx automatically (Debian / Ubuntu / Crostini):

      ./setup-linux.sh --install-docker

  Manual path:
      curl -fsSL https://get.docker.com | sh
      sudo usermod -aG docker "$USER"
      newgrp docker
EOF
    exit 1
fi

# Source the cross-platform body.
# shellcheck source=setup-common.sh
. "${repo_root}/setup-common.sh"
