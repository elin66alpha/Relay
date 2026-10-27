#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
LINUX_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd "$LINUX_DIR/../.." && pwd -P)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"

# Process names created by scripts/setup.sh via server/ecosystem.config.js.
SERVER_PROC="relay-server"
TUNNEL_PROC="relay-tunnel"
PM2_LOG_DIR="$HOME/.pm2/logs"

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }
# Every place setup waits for an answer opens with a banner, and each question
# starts with ASK, so the choices stand out from installer output.
section() {
  local rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '\n\033[1;36m%s\n  %s\n%s\033[0m\n' "$rule" "$*" "$rule"
}
ASK=$'\n\033[1;36m▶\033[0m '

need() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

require_pm2() {
  need pm2 || {
    c_err "pm2 is required. Install it with: npm install -g pm2"
    exit 1
  }
}

require_setup() {
  [ -f "$ENV_FILE" ] || {
    c_err "server/.env is missing. Run ./backends/linux/setup.sh first."
    exit 1
  }
  [ -d "$SERVER_DIR/node_modules" ] || {
    c_err "Backend dependencies are missing. Run ./backends/linux/setup.sh first."
    exit 1
  }
}

get_env() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true
}

# Matches ecosystem.config.js: anything other than "none" also runs a tunnel.
tunnel_mode() {
  local mode
  mode="$(get_env RELAY_TUNNEL_MODE)"
  printf '%s' "${mode:-quick}"
}

tunnel_enabled() {
  [ "$(tunnel_mode)" != "none" ]
}

pm2_has() { pm2 describe "$1" >/dev/null 2>&1; }

# Matches server.js: build/web is served unless RELAY_SERVE_WEB=0.
web_state() {
  if [ ! -f "$ROOT_DIR/build/web/index.html" ]; then
    printf 'not installed'
  elif [ "$(get_env RELAY_SERVE_WEB)" = "0" ]; then
    printf 'installed, disabled (RELAY_SERVE_WEB=0)'
  else
    printf 'served at /'
  fi
}
