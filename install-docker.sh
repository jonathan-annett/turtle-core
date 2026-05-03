#!/usr/bin/env bash
# install-docker.sh — install Docker + Compose for the host platform.
#
# Idempotent. Safe to re-run. Detects:
#   - Debian / Ubuntu / Crostini (apt + docker-ce)
#   - macOS (Homebrew + Colima)
#   - WSL2 (treated as its underlying Linux distro)
#
# Other Linux distros bail out with a pointer to docker.com/install.

set -euo pipefail

log() { printf '[install-docker] %s\n' "$*"; }
err() { printf '[install-docker] ERROR: %s\n' "$*" >&2; }

# ---- Platform detection ------------------------------------------------------

detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
          debian|ubuntu) echo "debian:$ID" ;;
          *)
            case "${ID_LIKE:-}" in
              *debian*|*ubuntu*) echo "debian:$ID" ;;
              *) echo "linux-other:$ID" ;;
            esac ;;
        esac
      else
        echo "linux-unknown"
      fi
      ;;
    *) echo "unsupported:$(uname -s)" ;;
  esac
}

# ---- Debian / Ubuntu / Crostini ---------------------------------------------

install_debian() {
  local vendor="$1"   # "debian" or "ubuntu"
  log "Installing Docker Engine via apt ($vendor)..."

  # Skip apt work if engine + compose plugin already present.
  if command -v docker >/dev/null 2>&1 \
     && docker compose version >/dev/null 2>&1 \
     && docker buildx version  >/dev/null 2>&1; then
    log "docker + compose + buildx already installed; skipping apt steps."
  else
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg

    sudo install -m 0755 -d /etc/apt/keyrings

    # Vendor-specific repo (debian vs ubuntu).
    # shellcheck disable=SC1091
    . /etc/os-release
    local repo_vendor codename
    case "$ID" in
      ubuntu) repo_vendor="ubuntu" ;;
      *)      repo_vendor="debian" ;;
    esac
    codename="$VERSION_CODENAME"

    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
      curl -fsSL "https://download.docker.com/linux/${repo_vendor}/gpg" \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${repo_vendor} ${codename} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update
    sudo apt-get install -y \
      docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin
  fi

  # Group membership — required for non-sudo docker access.
  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    log "Adding $USER to docker group..."
    sudo usermod -aG docker "$USER"
    log "Group change requires a new login shell. Run: newgrp docker"
    log "(or log out and back in) before re-running the substrate setup."
  fi

  # Fix ~/.docker ownership if a prior 'sudo docker' poisoned it.
  if [ -d "$HOME/.docker" ] && [ "$(stat -c %U "$HOME/.docker")" != "$USER" ]; then
    log "Fixing ~/.docker ownership (was root-owned, likely from a prior sudo docker invocation)..."
    sudo chown -R "$USER:$USER" "$HOME/.docker"
  fi
}

# ---- macOS -------------------------------------------------------------------

install_macos() {
  log "Installing Colima + Docker CLI via Homebrew (macOS)..."

  if ! command -v brew >/dev/null 2>&1; then
    err "Homebrew not found. Install from https://brew.sh and re-run."
    exit 1
  fi

  for pkg in colima docker docker-compose docker-buildx; do
    if brew list --formula "$pkg" >/dev/null 2>&1; then
      log "$pkg already installed."
    else
      brew install "$pkg"
    fi
  done

  # docker-buildx is installed as a brew formula but isn't auto-linked into
  # ~/.docker/cli-plugins, so 'docker buildx' fails until we symlink it.
  mkdir -p "$HOME/.docker/cli-plugins"
  if [ ! -e "$HOME/.docker/cli-plugins/docker-buildx" ]; then
    ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" \
            "$HOME/.docker/cli-plugins/docker-buildx"
  fi

  # Start Colima with resources sized for the substrate (see deployment-docker §7.2).
  if colima status >/dev/null 2>&1; then
    log "Colima already running."
  else
    log "Starting Colima with 4 CPU / 8 GB RAM..."
    colima start --cpu 4 --memory 8
  fi
}

# ---- Smoke test --------------------------------------------------------------

smoke_test() {
  log "Smoke test: docker info..."
  if docker info >/dev/null 2>&1; then
    log "Docker is working."
  else
    err "'docker info' failed."
    err "On Linux: log out/in (or run 'newgrp docker') so the group change takes effect."
    err "On macOS: check 'colima status'."
    exit 1
  fi
}

# ---- Already-installed fast path --------------------------------------------

already_installed() {
  command -v docker            >/dev/null 2>&1 \
    && docker info             >/dev/null 2>&1 \
    && docker compose version  >/dev/null 2>&1 \
    && docker buildx version   >/dev/null 2>&1
}

# ---- Main --------------------------------------------------------------------

main() {
  if already_installed; then
    log "Docker, Compose and Buildx already installed and working. Nothing to do."
    exit 0
  fi

  local platform
  platform=$(detect_platform)

  case "$platform" in
    debian:*)         install_debian "${platform#debian:}" ;;
    macos)            install_macos ;;
    linux-other:*)
      err "Linux distro '${platform#linux-other:}' not supported by this script."
      err "Install Docker Engine + Compose v2 manually, then re-run setup:"
      err "  https://docs.docker.com/engine/install/"
      exit 1 ;;
    linux-unknown)
      err "Could not identify Linux distro (no /etc/os-release). Install Docker manually."
      exit 1 ;;
    unsupported:*)
      err "Unsupported platform: ${platform#unsupported:}"
      exit 1 ;;
  esac

  smoke_test
}

main "$@"
