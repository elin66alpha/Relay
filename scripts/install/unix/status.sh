#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

c_info "Services ($PLATFORM_LABEL)"
svc_summary

c_info "Relay services"
for svc in server tunnel; do
  if svc_registered "$svc"; then
    printf '  %-8s registered\n' "$svc"
  elif [ "$svc" = tunnel ] && ! tunnel_enabled; then
    printf '  %-8s not used (RELAY_TUNNEL_MODE=none)\n' "$svc"
  else
    printf '  %-8s not registered\n' "$svc"
  fi
done

c_info "Address"
printf 'Backend URL: %s\n' "$(get_env PUBLIC_BASE_URL)"
printf 'Tunnel mode: %s\n' "$(tunnel_mode)"
case "$(tunnel_mode)" in
  cloudflare)
    config_file="$(named_tunnel_config)"
    if [ -f "$config_file" ]; then
      printf 'Tunnel name: %s\n' "$(basename "$config_file" .yml)"
      printf 'Tunnel id:   %s\n' "$(sed -nE 's/^tunnel: *//p' "$config_file")"
      sed -nE 's/^ *- hostname: */Hostname:    /p' "$config_file" | awk '!seen[$0]++'
    fi
    ;;
  quick)
    quick_url="$(latest_quick_url)"
    printf 'Quick Tunnel URL (latest in log): %s\n' "${quick_url:-not found}"
    ;;
esac
printf 'Port:        %s\n' "$(backend_port)"
printf 'Web client:  %s\n' "$(web_state)"
printf 'File access: %s\n' "$(file_access_state)"

if [ -d "$SERVER_DIR/node_modules" ]; then
  c_info "Agents"
  (cd "$SERVER_DIR" && node -e '
const { getAgentStatuses } = require("./lib/agent-status");
const { listAgents } = require("./lib/agents");
const statuses = getAgentStatuses();
for (const agent of listAgents()) {
  const s = statuses[agent.key] || {};
  const state = !s.installed ? "not installed" : s.authed === null ? "installed, sign-in managed on host" : s.authed ? "ready" : "installed, not signed in";
  console.log(`  ${agent.label.padEnd(12)} ${state}`);
}')

  c_info "Tokens"
  credential --list-tokens
fi

printf '\nLogs:\n'
{ server_log_files; tunnel_log_files; } | sed 's/^/  /'
printf '\n%s\n' "$(service_hint)"
