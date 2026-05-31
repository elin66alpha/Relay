#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos

c_info "AgentDeck macOS backend setup"

require_node
ensure_env_file
install_server_deps

PORT_NUM="$(backend_port)"
read -rp "Backend port [$PORT_NUM]: " PORT_INPUT
PORT_NUM="${PORT_INPUT:-$PORT_NUM}"
set_env PORT "$PORT_NUM"

read -rp "Use a Cloudflare quick tunnel for phone access? [Y/n]: " USE_TUNNEL
USE_TUNNEL="${USE_TUNNEL:-Y}"

PUBLIC_URL=""
case "$USE_TUNNEL" in
  [Nn]*)
    c_info "Direct mode"
    read -rp "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:$PORT_NUM): " PUBLIC_URL
    [ -n "$PUBLIC_URL" ] || { c_err "A public address is required in direct mode."; exit 1; }
    case "$PUBLIC_URL" in
      http://* | https://*) ;;
      *) PUBLIC_URL="http://$PUBLIC_URL"; c_warn "No scheme given; assuming $PUBLIC_URL" ;;
    esac
    set_env HOST 0.0.0.0
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    stop_agent "$TUNNEL_LABEL"
    rm -f "$TUNNEL_PLIST"
    ;;
  *)
    need cloudflared || {
      c_err "cloudflared is required for tunnel mode. Install with: brew install cloudflared"
      exit 1
    }
    c_info "Tunnel mode"
    set_env HOST 127.0.0.1
    rm -f "$LOG_DIR/tunnel.out.log" "$LOG_DIR/tunnel.err.log"
    ;;
esac

c_info "Installing LaunchAgent for backend"
write_server_plist
start_agent "$SERVER_LABEL" "$SERVER_PLIST"

if [ "${USE_TUNNEL#[Nn]}" = "$USE_TUNNEL" ]; then
  c_info "Installing LaunchAgent for cloudflared tunnel"
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
if [ "${USE_TUNNEL#[Nn]}" = "$USE_TUNNEL" ]; then
  c_info "Tunnel logs: $LOG_DIR/tunnel.out.log and $LOG_DIR/tunnel.err.log"
fi
