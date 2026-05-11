#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Assute/lightsail-monitor.git}"
BRANCH="${BRANCH:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/lightsail-monitor}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "请使用 root 执行，或先安装 sudo"
    exit 1
  fi
else
  SUDO=""
fi

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu|debian) echo "debian"; return ;;
      alpine) echo "alpine"; return ;;
      centos|rhel|rocky|almalinux|ol|fedora) echo "rhel"; return ;;
    esac
    case "${ID_LIKE:-}" in
      *debian*) echo "debian"; return ;;
      *rhel*|*fedora*) echo "rhel"; return ;;
      *alpine*) echo "alpine"; return ;;
    esac
  fi
  echo "unknown"
}

have_required_commands() {
  local cmd
  for cmd in git curl bash jq crontab ping node npm
  do
    if ! command -v "$cmd" >/dev/null 2>&1
    then
      return 1
    fi
  done
  return 0
}

install_packages() {
  local os_family="$1"

  if have_required_commands
  then
    return
  fi

  case "$os_family" in
    debian)
      $SUDO apt-get update
      $SUDO apt-get install -y git curl bash jq cron iputils-ping nodejs npm ca-certificates
      ;;
    alpine)
      $SUDO apk add --no-cache git curl bash jq dcron iputils nodejs npm ca-certificates
      ;;
    rhel)
      $SUDO yum install -y git curl bash jq cronie iputils nodejs npm ca-certificates
      ;;
    *)
      echo "暂不支持当前系统自动安装依赖，请手动安装：git curl bash jq cron ping nodejs npm"
      exit 1
      ;;
  esac
}

enable_cron() {
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now cron >/dev/null 2>&1 || true
    $SUDO systemctl enable --now crond >/dev/null 2>&1 || true
  fi
  if command -v service >/dev/null 2>&1; then
    $SUDO service cron start >/dev/null 2>&1 || true
    $SUDO service crond start >/dev/null 2>&1 || true
  fi
  if command -v rc-service >/dev/null 2>&1; then
    $SUDO rc-service crond start >/dev/null 2>&1 || true
  fi
  if command -v rc-update >/dev/null 2>&1; then
    $SUDO rc-update add crond default >/dev/null 2>&1 || true
  fi
}

prepare_repo() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    $SUDO git -C "$INSTALL_DIR" fetch --all --tags >/dev/null 2>&1
    $SUDO git -C "$INSTALL_DIR" checkout "$BRANCH" >/dev/null 2>&1 || $SUDO git -C "$INSTALL_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
    $SUDO git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH" >/dev/null 2>&1
    return
  fi

  if [ -f "$PWD/lightsail_monitor.js" ] && [ -f "$PWD/lightsail-monitor.sh" ]; then
    $SUDO mkdir -p "$INSTALL_DIR"
    $SUDO cp -a "$PWD/." "$INSTALL_DIR/"
    return
  fi

  $SUDO rm -rf "$INSTALL_DIR"
  $SUDO git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR" >/dev/null 2>&1
}

setup_node() {
  local hash_source
  local current_hash
  local hash_file

  cd "$INSTALL_DIR"

  if [ -f package-lock.json ]; then
    hash_source="package-lock.json"
  else
    hash_source="package.json"
  fi

  hash_file="$INSTALL_DIR/.npm-deps.hash"
  current_hash=$(sha256sum "$hash_source" | awk '{print $1}')

  if [ -d "$INSTALL_DIR/node_modules" ] && [ -f "$hash_file" ] && [ "$(cat "$hash_file")" = "$current_hash" ]; then
    return
  fi

  $SUDO npm install --silent
  printf '%s\n' "$current_hash" | $SUDO tee "$hash_file" >/dev/null
}

prepare_files() {
  if [ ! -f "$INSTALL_DIR/config.json" ] && [ -f "$INSTALL_DIR/config.example.json" ]; then
    $SUDO cp "$INSTALL_DIR/config.example.json" "$INSTALL_DIR/config.json"
  fi
  $SUDO chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/lightsail-monitor.sh" "$INSTALL_DIR/lightsail-ip.sh"
  $SUDO ln -sf "$INSTALL_DIR/lightsail-monitor.sh" /usr/local/bin/lightsail-monitor
}

main() {
  local os_family
  os_family=$(detect_os)
  install_packages "$os_family"
  prepare_repo
  setup_node
  prepare_files
  enable_cron

  exec bash "$INSTALL_DIR/lightsail-monitor.sh"
}

main "$@"
