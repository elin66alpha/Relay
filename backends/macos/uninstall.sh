#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos
c_info "Removing AgentDeck macOS LaunchAgent"
# Best-effort cleanup of the legacy cloudflared tunnel agent from older installs.
stop_agent "dev.agentdeck.tunnel"
rm -f "$LAUNCH_AGENTS_DIR/dev.agentdeck.tunnel.plist"
stop_agent "$SERVER_LABEL"
rm -f "$SERVER_PLIST"
c_info "Removed LaunchAgent. Backend data, tokens, credentials, and logs were left in place."
c_info "Networking is handled by Tailscale; remove this machine from your tailnet separately if desired."
