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

echo "How should the app reach this backend?"
echo "  1) Tailscale (recommended) - private, encrypted, stable address; never exposed to the public internet."
echo "  2) Direct - this host already has a reachable public IP or domain."
read -rp "Choose 1/2 [1]: " NET_MODE
NET_MODE="${NET_MODE:-1}"

PUBLIC_URL=""
case "$NET_MODE" in
  2)
    c_info "Direct mode"
    read -rp "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:$PORT_NUM): " PUBLIC_URL
    [ -n "$PUBLIC_URL" ] || { c_err "A public address is required in direct mode."; exit 1; }
    case "$PUBLIC_URL" in
      http://* | https://*) ;;
      *) PUBLIC_URL="http://$PUBLIC_URL"; c_warn "No scheme given; assuming $PUBLIC_URL" ;;
    esac
    set_env HOST 0.0.0.0
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    ;;
  *)
    need tailscale || { tailscale_install_hint; exit 1; }
    if ! tailscale status >/dev/null 2>&1; then
      c_err "Tailscale is installed but not connected. Run 'sudo tailscale up', then re-run setup."
      exit 1
    fi
    c_info "Tailscale mode"
    # The backend listens on the tailnet interface; reachability is provided by
    # Tailscale (WireGuard, end-to-end encrypted), not a public tunnel.
    set_env HOST 0.0.0.0
    PUBLIC_URL="$(detect_tailscale_url "$PORT_NUM")"
    [ -n "$PUBLIC_URL" ] && c_info "Tailscale address: $PUBLIC_URL"
    ;;
esac

c_info "Installing LaunchAgent for backend"
write_server_plist
start_agent "$SERVER_LABEL" "$SERVER_PLIST"

c_info "Generating credential QR"
cd "$SERVER_DIR"
if [ -n "$PUBLIC_URL" ]; then
  npm run credential -- --url "$PUBLIC_URL"
else
  # Tailscale mode with no detectable address yet: let the credential script
  # probe Tailscale itself (and surface guidance if it still can't find one).
  npm run credential
fi

c_info "Done"
c_info "Backend logs: $LOG_DIR/backend.out.log and $LOG_DIR/backend.err.log"
