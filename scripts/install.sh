#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

REPO_URL="https://github.com/smgdesign/pi-kiosk.git"
INSTALL_DIR="/home/$(whoami)/kiosk"
NODE_MAJOR=24
RESET_CREDENTIALS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reset)
      RESET_CREDENTIALS=true
      shift
      ;;
    *)
      print_error "Unknown option: $1"
      exit 1
      ;;
  esac
done

print_banner() {
  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}${BOLD}         Pi Kiosk Installer${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
}

print_step() {
  echo -e "${YELLOW}[*]${NC} $1"
}

print_done() {
  echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
  echo -e "${RED}[!]${NC} $1"
}

run_quiet() {
  local label="$1"
  shift
  if ! "$@" > /dev/null 2>&1; then
    print_error "$label - something went wrong. Re-running with details:"
    "$@"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/debian_version ]]; then
    print_error "This installer requires Raspberry Pi OS (Debian-based)."
    exit 1
  fi
}

select_site() {
  local sites_dir="$INSTALL_DIR/sites"
  local sites=()

  for f in "$sites_dir"/*.json; do
    [[ -f "$f" ]] || continue
    sites+=("$(basename "$f" .json)")
  done

  if [[ ${#sites[@]} -eq 0 ]]; then
    print_error "No site configurations found in $sites_dir"
    exit 1
  fi

  echo -e "${BOLD}Available sites:${NC}"
  echo ""
  for i in "${!sites[@]}"; do
    echo "  $((i+1))) ${sites[$i]}"
  done
  echo ""

  read -rp "  Select a site [1]: " choice < /dev/tty
  choice=${choice:-1}

  if [[ "$choice" -lt 1 || "$choice" -gt ${#sites[@]} ]]; then
    print_error "Invalid selection."
    exit 1
  fi

  SELECTED_SITE="${sites[$((choice-1))]}"
  cp "$sites_dir/${SELECTED_SITE}.json" "$INSTALL_DIR/config.json"
  print_done "Selected site: $SELECTED_SITE"
}

prompt_credentials() {
  echo ""
  echo -e "${BOLD}Enter login credentials for ${SELECTED_SITE}:${NC}"
  echo ""

  read -rp "  Username / email: " KIOSK_USERNAME < /dev/tty
  echo ""
  read -rsp "  Password: " KIOSK_PASSWORD < /dev/tty
  echo ""
  echo ""

  if [[ -z "$KIOSK_USERNAME" || -z "$KIOSK_PASSWORD" ]]; then
    print_error "Both fields are required."
    exit 1
  fi
}

install_node() {
  local current_major
  if command -v node &>/dev/null; then
    current_major=$(node -v | cut -d. -f1 | tr -d 'v')
  else
    current_major=0
  fi

  if [[ "$current_major" -lt "$NODE_MAJOR" ]]; then
    print_step "Installing services..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" 2>/dev/null | sudo -E bash - > /dev/null 2>&1
    run_quiet "Installing services" sudo apt-get install -y nodejs
    print_done "Services installed"
  else
    print_done "Services already installed"
  fi
}

install_project() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    print_step "Updating existing installation..."
    git -C "$INSTALL_DIR" pull --ff-only
    IS_UPDATE=true
  else
    IS_UPDATE=false
    # If running from inside the repo, copy files instead of cloning
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    if [[ -f "$REPO_ROOT/kiosk.mjs" && -f "$REPO_ROOT/package.json" ]]; then
      mkdir -p "$INSTALL_DIR"
      cp "$REPO_ROOT"/kiosk.mjs "$INSTALL_DIR/"
      cp "$REPO_ROOT"/package.json "$INSTALL_DIR/"
      cp "$REPO_ROOT"/strings.json "$INSTALL_DIR/"
      cp -r "$REPO_ROOT"/sites "$INSTALL_DIR/"
    else
      git clone "$REPO_URL" "$INSTALL_DIR" > /dev/null 2>&1
    fi
  fi

  print_step "Setting up automation..."
  run_quiet "Setting up automation" bash -c "cd $INSTALL_DIR && npm install"
  print_done "Automation ready"

  print_step "Downloading web browser (this may take a few minutes)..."
  run_quiet "Downloading web browser" bash -c "cd $INSTALL_DIR && npx playwright install chromium"
  print_done "Web browser downloaded"

  print_step "Configuring web browser..."
  run_quiet "Configuring web browser" bash -c "cd $INSTALL_DIR && sudo npx playwright install-deps chromium"
  print_done "Web browser configured"
}

write_env() {
  cat > "$INSTALL_DIR/.env" << EOF
KIOSK_USERNAME=${KIOSK_USERNAME}
KIOSK_PASSWORD=${KIOSK_PASSWORD}
EOF
  chmod 600 "$INSTALL_DIR/.env"
  print_done "Credentials saved"
}

install_service() {
  local current_user
  current_user="$(whoami)"
  local current_uid
  current_uid="$(id -u)"

  sudo tee /etc/systemd/system/kiosk.service > /dev/null << EOF
[Unit]
Description=Kiosk Dashboard
After=graphical.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${current_user}
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/${current_user}/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/${current_uid}
WorkingDirectory=${INSTALL_DIR}
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/node --env-file=${INSTALL_DIR}/.env ${INSTALL_DIR}/kiosk.mjs
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable kiosk.service
  print_done "Kiosk service enabled (starts on boot)"
}

print_summary() {
  echo ""
  echo -e "${GREEN}========================================${NC}"
  echo -e "${GREEN}${BOLD}      Installation Complete${NC}"
  echo -e "${GREEN}========================================${NC}"
  echo ""
  echo "  Installed to:  $INSTALL_DIR"
  echo "  Site:          $SELECTED_SITE"
  echo ""
  echo "  Useful commands:"
  echo "    sudo systemctl start kiosk    # Start now"
  echo "    sudo systemctl stop kiosk     # Stop"
  echo "    sudo systemctl status kiosk   # Check status"
  echo "    journalctl -u kiosk -f        # View logs"
  echo ""
  echo "  To change credentials later:"
  echo "    nano $INSTALL_DIR/.env"
  echo "    sudo systemctl restart kiosk"
  echo ""
}

main() {
  print_banner
  check_os
  install_node
  install_project

  if [[ "$IS_UPDATE" == true ]]; then
    if [[ "$RESET_CREDENTIALS" == true ]]; then
      SELECTED_SITE=$(jq -r '.name' "$INSTALL_DIR/config.json" 2>/dev/null || echo "kiosk")
      prompt_credentials
      write_env
    fi
    print_done "Update complete"
    echo ""
    if command -v systemctl &>/dev/null; then
      read -rp "Restart kiosk service now? (y/n): " RESTART < /dev/tty
      if [[ "$RESTART" == "y" || "$RESTART" == "Y" ]]; then
        sudo systemctl restart kiosk
        print_done "Kiosk service restarted"
      fi
    fi
    return
  fi

  select_site
  prompt_credentials
  write_env
  if command -v systemctl &>/dev/null; then
    install_service
  else
    print_step "systemd not available, skipping service install"
    print_done "Run manually: cd $INSTALL_DIR && node --env-file=.env kiosk.mjs"
  fi
  print_summary

  if command -v systemctl &>/dev/null; then
    read -rp "Reboot now to start the kiosk? (y/n): " REBOOT < /dev/tty
    if [[ "$REBOOT" == "y" || "$REBOOT" == "Y" ]]; then
      sudo reboot
    fi
  fi
}

main
