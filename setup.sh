#!/usr/bin/env bash
#
# AgentDeck one-command setup.
#
# Starts the backend with PM2, optionally opens a Cloudflare quick tunnel, then
# generates the credential QR that the AgentDeck app scans. Run from the repo
# root:
#
#   ./setup.sh
#
# Two modes:
#   - Tunnel mode (default): exposes localhost:8787 via a cloudflared quick
#     tunnel using PM2 + cloudflared.
#   - Direct mode: for a VPS / box with a reachable public IP or domain. Binds
#     the server to 0.0.0.0 and uses the address you provide; no tunnel.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"

SERVER_PROC="agentdeck-server"
TUNNEL_PROC="agentdeck-tunnel"

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

c_info "AgentDeck setup"
read -rp "Do you need a Cloudflare quick tunnel to expose this machine to the internet? [Y/n]: " USE_TUNNEL
USE_TUNNEL="${USE_TUNNEL:-Y}"

case "$USE_TUNNEL" in
  [Nn]*)
    # ---------- Direct mode (e.g. VPS with a public IP / domain) ----------
    c_info "Direct mode: the app connects straight to your address (no tunnel)."
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
    # ---------- Tunnel mode (Cloudflare quick tunnel) ----------
    need cloudflared || {
      c_err "cloudflared is required for tunnel mode."
      c_err "Install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
      exit 1
    }
    c_info "Tunnel mode: exposing localhost:${PORT_NUM} via a Cloudflare quick tunnel."

    # Tunnel reaches the server over localhost; keep it bound locally.
    set_env HOST 127.0.0.1

    # Fresh logs so we read THIS run's tunnel URL, not a stale one.
    rm -f "$HOME/.pm2/logs/${TUNNEL_PROC}-error.log" \
          "$HOME/.pm2/logs/${TUNNEL_PROC}-out.log"

    c_info "Starting backend + tunnel (PM2: $SERVER_PROC, $TUNNEL_PROC)..."
    pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js
    pm2 save >/dev/null 2>&1 || true

    c_info "Waiting for the tunnel URL..."
    TUNNEL_URL=""
    for _ in $(seq 1 30); do
      TUNNEL_URL="$(grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com' \
        "$HOME/.pm2/logs/${TUNNEL_PROC}-error.log" \
        "$HOME/.pm2/logs/${TUNNEL_PROC}-out.log" 2>/dev/null | tail -1 || true)"
      [ -n "$TUNNEL_URL" ] && break
      sleep 1
    done
    if [ -n "$TUNNEL_URL" ]; then
      c_info "Tunnel URL: $TUNNEL_URL"
    else
      c_warn "Tunnel URL not visible yet; the credential step will retry detection."
    fi

    c_info "Generating credential QR..."
    npm run credential
    ;;
esac

c_info "Done. In the app, tap \"Scan QR\", scan the QR above, and enter the password you just set."
c_info "Backend is managed by PM2 (pm2 list / pm2 logs / pm2 restart ${SERVER_PROC})."
