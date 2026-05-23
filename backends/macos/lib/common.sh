#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd "$MACOS_DIR/../.." && pwd -P)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"

SERVER_LABEL="dev.agentdeck.backend"
TUNNEL_LABEL="dev.agentdeck.tunnel"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/AgentDeck"
SERVER_PLIST="$LAUNCH_AGENTS_DIR/$SERVER_LABEL.plist"
TUNNEL_PLIST="$LAUNCH_AGENTS_DIR/$TUNNEL_LABEL.plist"

AGENTDECK_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1; }

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    c_err "This backend target must be run on macOS."
    exit 1
  fi
}

launch_domain() {
  printf 'gui/%s' "$(id -u)"
}

ensure_dirs() {
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
}

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    c_info "Created server/.env from .env.example"
  fi
}

set_env() {
  local key="$1" val="$2" tmp
  ensure_env_file
  if grep -qE "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*) printf '%s=%s\n' "$key" "$val" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$ENV_FILE" >"$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

get_env() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true
}

backend_port() {
  local port
  port="$(get_env PORT)"
  printf '%s' "${port:-8787}"
}

require_node() {
  need node || { c_err "Node.js 18+ is required. Install it with Homebrew: brew install node"; exit 1; }
  need npm || { c_err "npm is required."; exit 1; }
  local major
  major="$(node -p "Number(process.versions.node.split('.')[0])")"
  if [ "$major" -lt 18 ]; then
    c_err "Node.js 18+ is required. Current version: $(node -v)"
    exit 1
  fi
}

install_server_deps() {
  cd "$SERVER_DIR"
  if [ ! -d node_modules ]; then
    c_info "Installing backend dependencies..."
    npm install
  fi
}

write_server_plist() {
  ensure_dirs
  cat >"$SERVER_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$SERVER_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>node</string>
    <string>$SERVER_DIR/server.js</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$SERVER_DIR</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$AGENTDECK_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/backend.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/backend.err.log</string>
</dict>
</plist>
EOF
}

write_tunnel_plist() {
  local port="$1"
  ensure_dirs
  cat >"$TUNNEL_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$TUNNEL_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/env</string>
    <string>cloudflared</string>
    <string>tunnel</string>
    <string>--url</string>
    <string>http://127.0.0.1:$port</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$AGENTDECK_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$LOG_DIR/tunnel.out.log</string>
  <key>StandardErrorPath</key>
  <string>$LOG_DIR/tunnel.err.log</string>
</dict>
</plist>
EOF
}

start_agent() {
  local label="$1" plist="$2" domain
  domain="$(launch_domain)"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$plist"
  launchctl enable "$domain/$label" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$label"
}

stop_agent() {
  local label="$1" domain
  domain="$(launch_domain)"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
}

print_agent() {
  local label="$1" domain
  domain="$(launch_domain)"
  launchctl print "$domain/$label"
}

wait_for_tunnel_url() {
  local url=""
  for _ in $(seq 1 45); do
    url="$(grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com' \
      "$LOG_DIR/tunnel.out.log" "$LOG_DIR/tunnel.err.log" 2>/dev/null | tail -1 || true)"
    [ -n "$url" ] && break
    sleep 1
  done
  printf '%s' "$url"
}
