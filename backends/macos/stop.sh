#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos
c_info "Stopping AgentDeck tunnel and backend LaunchAgents"
stop_agent "$TUNNEL_LABEL"
stop_agent "$SERVER_LABEL"
c_info "Stopped"
