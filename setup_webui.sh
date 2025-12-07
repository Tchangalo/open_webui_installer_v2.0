#!/usr/bin/env bash
set -euo pipefail

# --- Color definitions ---
B='\033[0;94m'   # blue (info)
G='\033[0;32m'  # green (success)
Y='\e[33m'      # yellow (warning)
R='\033[91m'     # red (error)
NC='\033[0m'     # reset

# --- Configurable defaults ---
CHANNEL="${CHANNEL:-stable}"
COMPOSE_DEST="/usr/local/bin/docker-compose"
COMPOSE_TMP="/tmp/docker-compose.$$"
OVERRIDE_DIR="/etc/systemd/system/docker.service.d"
OVERRIDE_FILE="${OVERRIDE_DIR}/override.conf"
PORTAINER_VOLUME="portainer_data"
PORTAINER_NAME="portainer"
PORTAINER_IMAGE="portainer/portainer-ce"
PORTAINER_PORT_HTTP=9000
PORTAINER_PORT_EDGE=8000

# --- Determine sudo usage ---
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
else
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    printf '%b\n' "${R}ERROR: not running as root and sudo not available.${NC}" >&2
    exit 1
  fi
fi

# --- Logging helpers ---
info() { printf '%b\n' "${B}$*${NC}"; }
succ() { printf '%b\n' "${G}$*${NC}"; }
warn() { printf '%b\n' "${Y}$*${NC}"; }
err()  { printf '%b\n' "${R}ERROR: $*${NC}" >&2; }

# --- Status display ---
show_current_status() {
  # Show which modules are present and which containers are running.
  # This function prints a short summary before prompting the user.
  info "=== Current system status ==="

  # Docker presence
  if command -v docker >/dev/null 2>&1; then
    succ "Docker: installed"
    DOCKER_PRESENT=1
  else
    info "Docker: not installed"
    DOCKER_PRESENT=0
  fi

  # Docker Compose presence
  if [ -x "${COMPOSE_DEST}" ] || command -v docker-compose >/dev/null 2>&1; then
    succ "Docker Compose: installed"
    COMPOSE_PRESENT=1
  else
    info "Docker Compose: not installed"
    COMPOSE_PRESENT=0
  fi

  # Portainer container presence / running
  if command -v docker >/dev/null 2>&1; then
    if ${SUDO} docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "${PORTAINER_NAME}" >/dev/null 2>&1; then
      if ${SUDO} docker ps --format '{{.Names}}' 2>/dev/null | grep -x "${PORTAINER_NAME}" >/dev/null 2>&1; then
        succ "Portainer: container present and running (name='${PORTAINER_NAME}')"
        PORTAINER_PRESENT=1
        PORTAINER_RUNNING=1
      else
        warn "Portainer: container present but not running (name='${PORTAINER_NAME}')"
        PORTAINER_PRESENT=1
        PORTAINER_RUNNING=0
      fi
    else
      info "Portainer: no container present"
      PORTAINER_PRESENT=0
      PORTAINER_RUNNING=0
    fi
  else
    info "Portainer: docker not available — cannot check containers"
    PORTAINER_PRESENT=0
    PORTAINER_RUNNING=0
  fi

  # Open-WebUI container presence / running
  if command -v docker >/dev/null 2>&1; then
    if ${SUDO} docker ps -a --format '{{.Names}}' 2>/dev/null | grep -x "open-webui" >/dev/null 2>&1; then
      if ${SUDO} docker ps --format '{{.Names}}' 2>/dev/null | grep -x "open-webui" >/dev/null 2>&1; then
        succ "Open-WebUI: container present and running (name='open-webui')"
        WEBUI_PRESENT=1
        WEBUI_RUNNING=1
      else
        warn "Open-WebUI: container present but not running (name='open-webui')"
        WEBUI_PRESENT=1
        WEBUI_RUNNING=0
      fi
    else
      info "Open-WebUI: no container present"
      WEBUI_PRESENT=0
      WEBUI_RUNNING=0
    fi
  else
    info "Open-WebUI: docker not available — cannot check containers"
    WEBUI_PRESENT=0
    WEBUI_RUNNING=0
  fi

  info "============================="
}

# --- Docker ---
remove_docker_if_installed() {
  # Remove docker-related packages, data and files if present
  if command -v docker >/dev/null 2>&1 || dpkg -l 2>/dev/null | grep -E 'docker|containerd' >/dev/null 2>&1; then
    warn "Existing Docker installation detected — removing."
    ${SUDO} apt-get update -y
    ${SUDO} apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || true
    ${SUDO} apt-get autoremove -y || true
    ${SUDO} rm -rf /var/lib/docker /var/lib/containerd || true
    ${SUDO} rm -f /usr/local/bin/docker-compose /usr/bin/docker-compose || true
    # Also remove leftover docker systemd override if present
    ${SUDO} rm -f "${OVERRIDE_FILE}" || true
    ${SUDO} systemctl daemon-reload || true
    succ "Docker removal completed."
  else
    info "No Docker installation found."
  fi
}

install_docker() {
  # Install Docker using the official convenience script
  info "Installing Docker (channel=${CHANNEL})."
  if ! command -v curl >/dev/null 2>&1; then
    warn "curl missing — installing."
    ${SUDO} apt-get update -y
    ${SUDO} apt-get install -y curl ca-certificates gnupg lsb-release
  fi
  ${SUDO} bash -c "CHANNEL=${CHANNEL} && curl -fsSL https://get.docker.com | sh"
  ${SUDO} systemctl enable --now docker
  succ "Docker successfully installed."
}

add_user_to_docker_group() {
  # Add the invoking user (when using sudo) or $USER to docker group
  TARGET_USER="${SUDO:+${SUDO_USER:-$USER}}"
  if [ -n "${TARGET_USER}" ]; then
    if getent group docker >/dev/null 2>&1; then
      ${SUDO} usermod -aG docker "${TARGET_USER}" || err "user modification failed"
      succ "User '${TARGET_USER}' added to docker group."
    fi
  fi
}

# --- Docker Compose ---
remove_docker_compose_if_installed() {
  # Remove Docker Compose, if present
  if [ -x "${COMPOSE_DEST}" ] || command -v docker-compose >/dev/null 2>&1; then
    warn "Existing Docker Compose installation detected — removing."
    ${SUDO} rm -f "${COMPOSE_DEST}" || true
    ${SUDO} rm -f /usr/bin/docker-compose || true
    succ "Docker Compose removed."
  else
    info "No Docker Compose installation found."
  fi
}

install_docker_compose() {
  # Download and install latest Docker Compose release from GitHub
  info "Installing Docker Compose."
  LATEST_URL="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/docker/compose/releases/latest)"
  LATEST_TAG="${LATEST_URL##*/}"
  DOWNLOAD_URL="https://github.com/docker/compose/releases/download/${LATEST_TAG}/docker-compose-$(uname -s)-$(uname -m)"
  curl -fSL "${DOWNLOAD_URL}" -o "${COMPOSE_TMP}"
  ${SUDO} mv "${COMPOSE_TMP}" "${COMPOSE_DEST}"
  ${SUDO} chmod +x "${COMPOSE_DEST}"
  if ${SUDO} "${COMPOSE_DEST}" version >/dev/null 2>&1; then
    succ "Docker Compose installation successful."
  else
    err "Docker Compose installation failed."
    exit 1
  fi
}

# --- Portainer ---
apply_portainer_fix() {
  # Create systemd override to set DOCKER_MIN_API_VERSION for compatibility
  info "Applying Portainer compatibility fix."
  ${SUDO} mkdir -p "${OVERRIDE_DIR}"
  TMP="$(mktemp)"
  cat > "${TMP}" <<'EOF'
[Service]
Environment=DOCKER_MIN_API_VERSION=1.24
EOF
  ${SUDO} mv "${TMP}" "${OVERRIDE_FILE}"
  ${SUDO} chmod 644 "${OVERRIDE_FILE}"
  ${SUDO} systemctl daemon-reload
  ${SUDO} systemctl restart docker
  succ "Portainer compatibility fix applied."
}

install_portainer() {
  # Remove Portainer container, if present
  if ${SUDO} docker ps -a --format '{{.Names}}' | grep -x "${PORTAINER_NAME}" >/dev/null 2>&1; then
    warn "Existing Portainer container found — removing."
    ${SUDO} docker rm -f "${PORTAINER_NAME}" || true
  fi
  # Remove Portainer volume, if exists. COMMENT THIS OUT, IF YOU WANT TO KEEO YOUR DATA
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "${PORTAINER_VOLUME}" >/dev/null 2>&1; then
    ${SUDO} docker volume rm "${PORTAINER_VOLUME}" || true
    succ "Portainer volume '${PORTAINER_VOLUME}' removed."
  fi
  # Create volume and run Portainer container
  ${SUDO} docker volume create "${PORTAINER_VOLUME}" >/dev/null
  info "Deploying Portainer container."
  ${SUDO} docker run -d \
    -p ${PORTAINER_PORT_EDGE}:8000 -p ${PORTAINER_PORT_HTTP}:9000 \
    --name "${PORTAINER_NAME}" \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "${PORTAINER_VOLUME}:/data" \
    "${PORTAINER_IMAGE}"
  succ "Portainer deployed on ports ${PORTAINER_PORT_HTTP} and ${PORTAINER_PORT_EDGE}."
  # Indicate that a container was started
  CONTAINERS_STARTED=$((CONTAINERS_STARTED+1))
}

remove_portainer_if_installed() {
  # Remove Portainer container, if present
  if ${SUDO} docker ps -a --format '{{.Names}}' | grep -x "${PORTAINER_NAME}" >/dev/null 2>&1; then
    warn "Removing existing Portainer container."
    ${SUDO} docker rm -f "${PORTAINER_NAME}" || true
  else
    info "No Portainer container present."
  fi
  # Remove Portainer volume, if exists. COMMENT THIS OUT, IF YOU WANT TO KEEO YOUR DATA
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "${PORTAINER_VOLUME}" >/dev/null 2>&1; then
    ${SUDO} docker volume rm "${PORTAINER_VOLUME}" || true
    succ "Portainer volume '${PORTAINER_VOLUME}' removed."
  fi
}

# --- Open WebUI ---
install_webui() {
  info "Starting Open-WebUI installation."
  # Remove Open WebUI Container, if exists
  if ${SUDO} docker ps -a --format '{{.Names}}' | grep -x "open-webui" >/dev/null 2>&1; then
    warn "Existing open-webui container found — removing."
    ${SUDO} docker rm -f open-webui || true
  fi
  # Remove volumes if present. COMMENT THIS OUT IF YOU WANT TO KEEP YOUR DATA/MODELS
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "ollama" >/dev/null 2>&1; then
    ${SUDO} docker volume rm ollama || true
    succ "Volume 'ollama' removed."
  fi
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "open-webui" >/dev/null 2>&1; then
    ${SUDO} docker volume rm open-webui || true
    succ "Volume 'open-webui' removed."
  fi
  # Deploy Open-WebUI container (ollama-backed)
  info "Creating volumes (ollama, open-webui)."
  ${SUDO} docker volume create ollama >/dev/null || true
  ${SUDO} docker volume create open-webui >/dev/null || true
  info "Deploying Open-WebUI container."
  ${SUDO} docker run -d \
    -p 3000:8080 \
    -v ollama:/root/.ollama \
    -v open-webui:/app/backend/data \
    --name open-webui \
    --restart always \
    ghcr.io/open-webui/open-webui:ollama
  succ "Open-WebUI running on port 3000."
  # Indicate that a container was started
  CONTAINERS_STARTED=$((CONTAINERS_STARTED+1))
}

remove_webui_if_installed() {
  # Remove Open Webui container , if present
  if ${SUDO} docker ps -a --format '{{.Names}}' | grep -x "open-webui" >/dev/null 2>&1; then
    warn "Removing existing open-webui container."
    ${SUDO} docker rm -f open-webui || true
  else
    info "No open-webui container present."
  fi
  # Remove Open WebUI volumes if present. COMMENT THIS OUT IF YOU WANT TO KEEP YOUR DATA/MODELS
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "ollama" >/dev/null 2>&1; then
    ${SUDO} docker volume rm ollama || true
    succ "Volume 'ollama' removed."
  fi
  if ${SUDO} docker volume ls --format '{{.Name}}' | grep -x "open-webui" >/dev/null 2>&1; then
    ${SUDO} docker volume rm open-webui || true
    succ "Volume 'open-webui' removed."
  fi
}

# --- User selection prompt ---
prompt_yes_no() {
  local resp
  while true; do
    read -r -p "$1 [y/N]: " resp
    case "${resp,,}" in
      y|yes) return 0 ;;
      n|no|"") return 1 ;;
      *) printf '%b\n' "${Y}Please enter '\''y'\'' or '\''n'\'.${NC}" ;;
    esac
  done
}

prompt_action() {
  # Ask user whether they want to Install or Remove
  local resp
  while true; do
    read -r -p "Do you want to (i)nstall or (r)emove modules? [i/r]: " resp
    case "${resp,,}" in
      i|install) echo "install"; return 0 ;;
      r|remove|uninstall|deinstall) echo "remove"; return 0 ;;
      *)
        printf '%b\n' "${Y}Please enter 'i' (install) or 'r' (remove).${NC}"
        ;;
    esac
  done
}

# --- Main execution ---
main() {
  # Show current status before prompting the user
  show_current_status

  info "=== Select action and modules ==="

  ACTION="$(prompt_action)"
  # Initialize selections as empty
  DOCKER_SEL=""
  COMPOSE_SEL=""
  PORTAINER_SEL=""
  WEBUI_SEL=""

  if [ "${ACTION}" = "install" ]; then
    if prompt_yes_no "Install Docker?"; then DOCKER_SEL="yes"; else DOCKER_SEL="no"; fi
    if prompt_yes_no "Install Docker Compose?"; then COMPOSE_SEL="yes"; else COMPOSE_SEL="no"; fi
    if prompt_yes_no "Install Portainer?"; then PORTAINER_SEL="yes"; else PORTAINER_SEL="no"; fi
    if prompt_yes_no "Install Open-WebUI?"; then WEBUI_SEL="yes"; else WEBUI_SEL="no"; fi
  else
    if prompt_yes_no "Remove Docker (and associated data)?"; then DOCKER_SEL="yes"; else DOCKER_SEL="no"; fi
    if prompt_yes_no "Remove Docker Compose?"; then COMPOSE_SEL="yes"; else COMPOSE_SEL="no"; fi
    if prompt_yes_no "Remove Portainer (container + volume)?"; then PORTAINER_SEL="yes"; else PORTAINER_SEL="no"; fi
    if prompt_yes_no "Remove Open-WebUI (container + volumes)?"; then WEBUI_SEL="yes"; else WEBUI_SEL="no"; fi
  fi

  ACTIONS_PERFORMED=0
  INSTALL_COUNT=0
  CONTAINERS_STARTED=0
  WEBUI_INSTALLED=0

  # Docker
  if [[ "${DOCKER_SEL}" == "yes" && "${ACTION}" == "install" ]]; then
    info "==> Docker: starting installation"
    remove_docker_if_installed
    install_docker
    add_user_to_docker_group
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
    INSTALL_COUNT=$((INSTALL_COUNT+1))
  elif [[ "${DOCKER_SEL}" == "yes" && "${ACTION}" == "remove" ]]; then
    info "==> Docker: starting removal"
    remove_docker_if_installed
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
  fi

  # Docker Compose
  if [[ "${COMPOSE_SEL}" == "yes" && "${ACTION}" == "install" ]]; then
    info "==> Docker Compose: starting installation"
    remove_docker_compose_if_installed
    install_docker_compose
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
    INSTALL_COUNT=$((INSTALL_COUNT+1))
  elif [[ "${COMPOSE_SEL}" == "yes" && "${ACTION}" == "remove" ]]; then
    info "==> Docker Compose: starting removal"
    remove_docker_compose_if_installed
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
  fi

  # Portainer
  if [[ "${PORTAINER_SEL}" == "yes" && "${ACTION}" == "install" ]]; then
    info "==> Portainer: starting installation"
    apply_portainer_fix
    install_portainer
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
    INSTALL_COUNT=$((INSTALL_COUNT+1))
  elif [[ "${PORTAINER_SEL}" == "yes" && "${ACTION}" == "remove" ]]; then
    info "==> Portainer: starting removal"
    remove_portainer_if_installed
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
  fi

  # Open-WebUI
  if [[ "${WEBUI_SEL}" == "yes" && "${ACTION}" == "install" ]]; then
    info "==> Open-WebUI: starting installation"
    install_webui
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
    INSTALL_COUNT=$((INSTALL_COUNT+1))
    WEBUI_INSTALLED=$((WEBUI_INSTALLED+1))
  elif [[ "${WEBUI_SEL}" == "yes" && "${ACTION}" == "remove" ]]; then
    info "==> Open-WebUI: starting removal"
    remove_webui_if_installed
    ACTIONS_PERFORMED=$((ACTIONS_PERFORMED+1))
  fi

  if [ "${ACTIONS_PERFORMED}" -gt 0 ]; then
      succ "=== Selected actions completed (${ACTIONS_PERFORMED} tasks executed) ==="
  fi

show_current_status

# --- Reboot only if Open-WebUI was newly set up ---
  if [ "${WEBUI_INSTALLED}" -eq 1 ]; then
      info "Open WebUI was (re)installed — rebooting..."
      ${SUDO:-} reboot
  else
      info "Open WebUI not installed this run — reboot skipped."
  fi

}

main "$@"
