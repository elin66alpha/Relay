#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos

c_info "Relay macOS backend setup"

require_node
ensure_env_file
install_server_deps

PORT_NUM="$(backend_port)"
read -rp "Backend port [$PORT_NUM]: " PORT_INPUT
PORT_NUM="${PORT_INPUT:-$PORT_NUM}"
set_env PORT "$PORT_NUM"

cat <<EOF
Choose network mode:
  1) No tunnel / direct public address
  2) Cloudflare Tunnel / named stable hostname
  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL
EOF
read -rp "Network mode [1/2/3, default 3]: " NETWORK_MODE
NETWORK_MODE="${NETWORK_MODE:-3}"

PUBLIC_URL=""
case "$NETWORK_MODE" in
  1)
    c_info "Direct mode"
    read -rp "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:$PORT_NUM): " PUBLIC_URL
    [ -n "$PUBLIC_URL" ] || { c_err "A public address is required in direct mode."; exit 1; }
    case "$PUBLIC_URL" in
      http://* | https://*) ;;
      *) PUBLIC_URL="http://$PUBLIC_URL"; c_warn "No scheme given; assuming $PUBLIC_URL" ;;
    esac
    set_env HOST 0.0.0.0
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    set_env RELAY_TUNNEL_MODE none
    set_env CLOUDFLARED_BIN ""
    stop_agent "$TUNNEL_LABEL"
    rm -f "$TUNNEL_PLIST"
    ;;
  2)
    need cloudflared || {
      c_err "cloudflared is required for Cloudflare Tunnel mode. Install with: brew install cloudflared"
      exit 1
    }
    c_info "Cloudflare Tunnel mode"
    read -rp "Public hostname for this backend (e.g. agent.example.com): " PUBLIC_HOSTNAME
    PUBLIC_HOSTNAME="$(url_hostname "$PUBLIC_HOSTNAME")"
    [ -n "$PUBLIC_HOSTNAME" ] || { c_err "A hostname is required for Cloudflare Tunnel mode."; exit 1; }
    DEFAULT_TUNNEL_NAME="$(default_tunnel_name)"
    read -rp "Cloudflare tunnel name [$DEFAULT_TUNNEL_NAME]: " TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-$DEFAULT_TUNNEL_NAME}"
    TUNNEL_NAME="$(printf '%s' "$TUNNEL_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
    [ -n "$TUNNEL_NAME" ] || { c_err "A tunnel name is required."; exit 1; }
    TUNNEL_ID="$(ensure_named_tunnel "$TUNNEL_NAME")"
    ensure_tunnel_dns_route "$TUNNEL_NAME" "$PUBLIC_HOSTNAME"
    PUBLIC_URL="https://$PUBLIC_HOSTNAME"
    CONFIG_FILE="$SERVER_DIR/cloudflared-config/${TUNNEL_NAME}.yml"
    write_named_tunnel_config "$TUNNEL_ID" "$PUBLIC_HOSTNAME" "$PORT_NUM" "$CONFIG_FILE"
    set_env HOST 127.0.0.1
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    set_env RELAY_TUNNEL_MODE cloudflare
    set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
    rm -f "$LOG_DIR/tunnel.out.log" "$LOG_DIR/tunnel.err.log"
    ;;
  3)
    need cloudflared || {
      c_err "cloudflared is required for Quick Tunnel mode. Install with: brew install cloudflared"
      exit 1
    }
    c_info "Quick Tunnel mode"
    set_env HOST 127.0.0.1
    set_env RELAY_TUNNEL_MODE quick
    set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
    rm -f "$LOG_DIR/tunnel.out.log" "$LOG_DIR/tunnel.err.log"
    ;;
  *)
    c_err "Invalid network mode: $NETWORK_MODE"
    exit 1
    ;;
esac

c_info "Installing LaunchAgent for backend"
write_server_plist
start_agent "$SERVER_LABEL" "$SERVER_PLIST"

if [ "$NETWORK_MODE" = "2" ]; then
  c_info "Installing LaunchAgent for Cloudflare Tunnel"
  write_named_tunnel_plist "$CONFIG_FILE" "$TUNNEL_ID"
  start_agent "$TUNNEL_LABEL" "$TUNNEL_PLIST"
elif [ "$NETWORK_MODE" = "3" ]; then
  c_info "Installing LaunchAgent for Cloudflare Quick Tunnel"
  write_tunnel_plist "$PORT_NUM"
  start_agent "$TUNNEL_LABEL" "$TUNNEL_PLIST"

  c_info "Waiting for tunnel URL..."
  PUBLIC_URL="$(wait_for_tunnel_url)"
  if [ -z "$PUBLIC_URL" ]; then
    c_err "Could not detect a trycloudflare URL. Check: $LOG_DIR/tunnel.err.log"
    exit 1
  fi
  set_env PUBLIC_BASE_URL "$PUBLIC_URL"
  c_info "Tunnel URL: $PUBLIC_URL"
fi

c_info "Generating credential QR"
cd "$SERVER_DIR"
npm run credential -- --url "$PUBLIC_URL"

c_info "Done"
c_info "Backend logs: $LOG_DIR/backend.out.log and $LOG_DIR/backend.err.log"
if [ "$NETWORK_MODE" = "2" ] || [ "$NETWORK_MODE" = "3" ]; then
  c_info "Tunnel logs: $LOG_DIR/tunnel.out.log and $LOG_DIR/tunnel.err.log"
fi
