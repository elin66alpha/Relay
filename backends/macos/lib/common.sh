#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT_DIR="$(cd "$MACOS_DIR/../.." && pwd -P)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"

SERVER_LABEL="dev.agentdeck.backend"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/AgentDeck"
SERVER_PLIST="$LAUNCH_AGENTS_DIR/$SERVER_LABEL.plist"

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

# Print cross-platform Tailscale install guidance.
tailscale_install_hint() {
  c_err "Tailscale is required for the recommended networking mode."
  c_warn "Install it (one time), log in, then re-run setup:"
  c_warn "  macOS:  brew install tailscale && sudo tailscale up   (or the Mac App Store app)"
  c_warn "  Install Tailscale on your phone / other client devices too, signed into the same account."
  c_warn "  Download: https://tailscale.com/download"
}

# Echo this machine's stable Tailscale address (http://<100.x-ip-or-magicdns>:<port>),
# or nothing if Tailscale is not connected. The 100.x tailnet IP is preferred
# because it does not depend on client-side MagicDNS being enabled.
detect_tailscale_url() {
  local port="$1" host=""
  host="$(tailscale ip -4 2>/dev/null | head -1 | tr -d '[:space:]' || true)"
  if [ -z "$host" ]; then
    host="$(tailscale status --json 2>/dev/null \
      | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's/.*"DNSName"[[:space:]]*:[[:space:]]*"([^"]+)\.?"/\1/' || true)"
    host="${host%.}"
  fi
  [ -n "$host" ] && printf 'http://%s:%s' "$host" "$port"
}
