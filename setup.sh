#!/usr/bin/env bash
#
# AgentDeck one-command setup.
#
# Starts the backend with PM2, then generates the credential QR that the
# AgentDeck app scans. Run from the repo root:
#
#   ./setup.sh
#
# Networking has two modes:
#   - Tailscale mode (recommended, default): the backend is reached over your
#     private tailnet at a stable MagicDNS address. No public exposure, no
#     rotating URL, works behind NAT/CGNAT, cross-platform. Requires Tailscale
#     on the host and on each client device (one install + login).
#   - Direct mode: for a VPS / box with a reachable public IP or domain. Binds
#     the server to 0.0.0.0 and uses the address you provide.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"

SERVER_PROC="agentdeck-server"

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null 2>&1; }

# Upsert KEY=VALUE into server/.env (pure bash; safe for URLs with / and :).
set_env() {
  local key="$1" val="$2" tmp
  [ -f "$ENV_FILE" ] || : >"$ENV_FILE"
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

# ---- prerequisites ----
need node || { c_err "Node.js >= 18 is required."; exit 1; }
need npm  || { c_err "npm is required."; exit 1; }
need pm2  || { c_err "pm2 is required. Install it with: npm install -g pm2"; exit 1; }

cd "$SERVER_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  c_info "Created server/.env from .env.example"
fi
if [ ! -d node_modules ]; then
  c_info "Installing server dependencies..."
  npm install
fi

PORT_NUM="$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2 || true)"
PORT_NUM="${PORT_NUM:-8787}"

# Print cross-platform Tailscale install guidance, then exit non-zero.
tailscale_install_hint() {
  c_err "Tailscale is required for the recommended networking mode."
  c_warn "Install it (one time), log in, then re-run ./setup.sh:"
  case "$(uname -s)" in
    Darwin) c_warn "  macOS:  brew install tailscale && sudo tailscale up   (or the Mac App Store app)" ;;
    Linux)  c_warn "  Linux:  curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up" ;;
    *)      c_warn "  Download: https://tailscale.com/download" ;;
  esac
  c_warn "  Install Tailscale on your phone / other client devices too, signed into the same account."
  c_warn "Or choose Direct mode (option 2) if this host has a public IP or domain."
}

c_info "AgentDeck setup"
echo "How should the app reach this backend?"
echo "  1) Tailscale (recommended) - private, encrypted, stable address; never exposed to the public internet."
echo "  2) Direct - this host already has a reachable public IP or domain (e.g. a VPS)."
read -rp "Choose 1/2 [1]: " NET_MODE
NET_MODE="${NET_MODE:-1}"

case "$NET_MODE" in
  2)
    # ---------- Direct mode (e.g. VPS with a public IP / domain) ----------
    c_info "Direct mode: the app connects straight to your address."
    read -rp "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:${PORT_NUM}): " PUBLIC_URL
    [ -n "$PUBLIC_URL" ] || { c_err "A public address is required in direct mode."; exit 1; }
    case "$PUBLIC_URL" in
      http://* | https://*) ;;
      *) PUBLIC_URL="http://$PUBLIC_URL"; c_warn "No scheme given; assuming $PUBLIC_URL" ;;
    esac

    # Bind to all interfaces so the public IP/domain can reach the server.
    set_env HOST 0.0.0.0
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"

    c_info "Starting backend (PM2: $SERVER_PROC)..."
    pm2 delete "$SERVER_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js --only "$SERVER_PROC"
    pm2 save >/dev/null 2>&1 || true

    c_warn "Make sure port ${PORT_NUM} is open in your firewall / security group, and that"
    c_warn "${PUBLIC_URL} actually reaches this machine (directly or via a reverse proxy)."
    c_warn "For HTTPS, terminate TLS at a reverse proxy (nginx/Caddy) in front of port ${PORT_NUM}."

    c_info "Generating credential QR..."
    npm run credential -- --url "$PUBLIC_URL"
    ;;
  *)
    # ---------- Tailscale mode (recommended) ----------
    need tailscale || { tailscale_install_hint; exit 1; }
    if ! tailscale status >/dev/null 2>&1; then
      c_err "Tailscale is installed but not connected."
      c_warn "Run 'sudo tailscale up' to log in, then re-run ./setup.sh."
      exit 1
    fi

    # The backend listens on the tailnet interface; reachability is provided by
    # Tailscale (WireGuard, end-to-end encrypted), not a public tunnel.
    set_env HOST 0.0.0.0

    c_info "Starting backend (PM2: $SERVER_PROC)..."
    pm2 delete "$SERVER_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js --only "$SERVER_PROC"
    pm2 save >/dev/null 2>&1 || true

    TS_NAME="$(tailscale status --json 2>/dev/null \
      | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's/.*"DNSName"[[:space:]]*:[[:space:]]*"([^"]+)\.?"/\1/' || true)"
    [ -n "$TS_NAME" ] && c_info "Tailscale address: http://${TS_NAME%.}:${PORT_NUM}"
    c_warn "Tip: for tailnet-only access with HTTPS, you can instead run:"
    c_warn "  tailscale serve --bg ${PORT_NUM}   (then regenerate the QR with the https URL)"

    c_info "Generating credential QR (auto-detects the Tailscale address)..."
    npm run credential
    ;;
esac

c_info "Done. In the app, tap \"Scan QR\", scan the QR above, and enter the password you just set."
c_info "Backend is managed by PM2 (pm2 list / pm2 logs / pm2 restart ${SERVER_PROC})."
