#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_macos

print_one() {
  local label="$1"
  printf '\n== %s ==\n' "$label"
  if print_agent "$label" 2>/dev/null; then
    return 0
  fi
  printf 'not loaded\n'
}

print_one "$SERVER_LABEL"

printf '\nLogs:\n'
printf '  %s\n' "$LOG_DIR/backend.out.log" "$LOG_DIR/backend.err.log"

printf '\nNetworking: Tailscale (run `tailscale status` to check the tailnet).\n'
