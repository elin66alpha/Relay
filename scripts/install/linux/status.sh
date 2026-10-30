#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_pm2

c_info "PM2 processes"
pm2 list

c_info "Relay processes"
for proc in "$SERVER_PROC" "$TUNNEL_PROC"; do
  if pm2_has "$proc"; then
    printf '  %-14s registered\n' "$proc"
  elif [ "$proc" = "$TUNNEL_PROC" ] && ! tunnel_enabled; then
    printf '  %-14s not used (RELAY_TUNNEL_MODE=none)\n' "$proc"
  else
    printf '  %-14s not registered\n' "$proc"
  fi
done

c_info "Address"
printf 'Backend URL: %s\n' "$(get_env PUBLIC_BASE_URL)"
printf 'Tunnel mode: %s\n' "$(tunnel_mode)"
case "$(tunnel_mode)" in
  cloudflare)
    # CLOUDFLARED_ARGS is "tunnel --config <file> run <id>", written by setup.
    config_file="$(get_env CLOUDFLARED_ARGS | sed -nE 's/.*--config ([^ ]+).*/\1/p')"
    if [ -f "$config_file" ]; then
      printf 'Tunnel name: %s\n' "$(basename "$config_file" .yml)"
      printf 'Tunnel id:   %s\n' "$(sed -nE 's/^tunnel: *//p' "$config_file")"
      sed -nE 's/^ *- hostname: */Hostname:    /p' "$config_file" | awk '!seen[$0]++'
    fi
    ;;
  quick)
    quick_url="$(grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com' \
      "$PM2_LOG_DIR/$TUNNEL_PROC-error.log" "$PM2_LOG_DIR/$TUNNEL_PROC-out.log" 2>/dev/null | tail -1 || true)"
    printf 'Quick Tunnel URL (latest in log): %s\n' "${quick_url:-not found}"
    ;;
esac
printf 'Port:        %s\n' "$(get_env PORT)"
printf 'Web client:  %s\n' "$(web_state)"

if [ -d "$SERVER_DIR/node_modules" ]; then
  c_info "Agents"
  (cd "$SERVER_DIR" && node -e '
const { getAgentStatuses } = require("./lib/agent-status");
const { listAgents } = require("./lib/agents");
const statuses = getAgentStatuses();
for (const agent of listAgents()) {
  const s = statuses[agent.key] || {};
  const state = !s.installed ? "not installed" : s.authed ? "ready" : "installed, not signed in";
  console.log(`  ${agent.label.padEnd(12)} ${state}`);
}')

  c_info "Tokens"
  (cd "$SERVER_DIR" && node scripts/create-credential.js --list-tokens)
fi

printf '\nLogs:\n'
printf '  %s\n' \
  "$PM2_LOG_DIR/$SERVER_PROC-out.log" \
  "$PM2_LOG_DIR/$SERVER_PROC-error.log" \
  "$PM2_LOG_DIR/$TUNNEL_PROC-out.log" \
  "$PM2_LOG_DIR/$TUNNEL_PROC-error.log"
printf '\nFollow them with: pm2 logs %s\n' "$SERVER_PROC"
