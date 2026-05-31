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

# Make sure Tailscale is installed and this machine is connected to a tailnet.
# On Linux we offer to install it via the official script; everywhere we run
# `tailscale up` (interactive login) when not already connected.
ensure_tailscale() {
  if ! need tailscale; then
    if [ "$(uname -s)" = "Linux" ]; then
      read -rp "Tailscale is not installed. Install it now (official script, needs sudo)? [Y/n]: " yn
      case "${yn:-Y}" in
        [Nn]*) tailscale_install_hint; exit 1 ;;
        *) c_info "Installing Tailscale..."; curl -fsSL https://tailscale.com/install.sh | sh ;;
      esac
      need tailscale || { c_err "Tailscale not found on PATH after install."; exit 1; }
    else
      tailscale_install_hint
      exit 1
    fi
  fi
  if ! tailscale status >/dev/null 2>&1; then
    c_info "Connecting this machine to your tailnet..."
    c_warn "A login URL will be printed below - open it on ANY browser (phone/laptop) and sign in."
    c_warn "Headless / no browser at all? Cancel (Ctrl-C) and run:"
    c_warn "  sudo tailscale up --authkey <key>   (create one at https://login.tailscale.com/admin/settings/keys)"
    sudo tailscale up
  fi
  tailscale status >/dev/null 2>&1 || {
    c_err "Still not connected to a tailnet. Run 'sudo tailscale up', then re-run ./setup.sh."
    exit 1
  }
}

c_info "AgentDeck setup"
echo "How should the app reach this backend?"
echo "  1) Tailscale Funnel (recommended) - public, encrypted MagicDNS address exposed to the internet."
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
    # ---------- Tailscale Funnel mode (recommended) ----------
    ensure_tailscale

    # The backend listens locally; Tailscale Funnel routes to it.
    set_env HOST 127.0.0.1

    c_info "Starting backend (PM2: $SERVER_PROC)..."
    pm2 delete "$SERVER_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js --only "$SERVER_PROC"
    pm2 save >/dev/null 2>&1 || true

    TS_NAME="$(tailscale status --json 2>/dev/null \
      | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
      | sed -E 's/.*"DNSName"[[:space:]]*:[[:space:]]*"([^"]+)\.?"/\1/' || true)"
    TS_NAME="${TS_NAME%.}"

    if [ -z "$TS_NAME" ]; then
      c_err "Could not determine MagicDNS name. Ensure Tailscale is connected."
      exit 1
    fi

    FUNNEL_URL="https://${TS_NAME}"
    set_env PUBLIC_BASE_URL "$FUNNEL_URL"

    c_info "Ensuring Tailscale Funnel is active for port ${PORT_NUM}..."
    tailscale funnel --bg "${PORT_NUM}" || true

    c_info "Tailscale Funnel address used in QR: ${FUNNEL_URL}"
    c_info "Generating credential QR..."
    npm run credential -- --url "$FUNNEL_URL"

    BASE_URL="$FUNNEL_URL"
    c_info "Next steps to connect your devices:"
    c_warn "  Any client can now reach your backend over the public internet via:"
    c_warn "  ${BASE_URL}"
    c_warn "  In AgentDeck tap \"Scan QR\", scan the QR above, enter the password."
    ;;

esac

c_info "Done. Backend is managed by PM2 (pm2 list / pm2 logs / pm2 restart ${SERVER_PROC})."
