#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos
require_node
ensure_env_file
install_server_deps

c_info "Starting AgentDeck backend LaunchAgent"
write_server_plist
start_agent "$SERVER_LABEL" "$SERVER_PLIST"

c_info "Done. Logs are in $LOG_DIR"
