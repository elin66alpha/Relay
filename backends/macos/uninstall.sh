#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos
c_info "Removing AgentDeck macOS LaunchAgent"
stop_agent "$TUNNEL_LABEL"
rm -f "$TUNNEL_PLIST"
stop_agent "$SERVER_LABEL"
rm -f "$SERVER_PLIST"
c_info "Removed LaunchAgent. Backend data, tokens, credentials, and logs were left in place."
