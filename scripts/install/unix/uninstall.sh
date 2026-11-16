#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

refuse_sudo uninstall.sh

c_info "Removing Relay services"
svc_remove

if [ -d "$WEB_DIR" ]; then
  rm -rf "$WEB_DIR"
  c_info "Removed the Web client ($WEB_DIR)."
fi

if [ "$(tunnel_mode)" = "cloudflare" ] && need cloudflared; then
  config_file="$(named_tunnel_config)"
  tunnel_name="$(basename "${config_file:-}" .yml)"
  if [ -n "$tunnel_name" ] && ask_no "Delete the Cloudflare Tunnel '$tunnel_name' from your Cloudflare account?"; then
    cloudflared tunnel cleanup "$tunnel_name" >/dev/null 2>&1 || true
    if cloudflared tunnel delete "$tunnel_name"; then
      rm -f "$config_file"
      c_warn "Its DNS record (CNAME to <id>.cfargotunnel.com) stays; delete it in the Cloudflare dashboard."
    fi
  fi
fi

c_info "System software"
remove_system_software

c_info "Uninstalled."
cat <<EOF
Backend data was left in place on purpose. Delete it yourself if you are
retiring this host:

  $SERVER_DIR/.env
  $SERVER_DIR/tokens.json          (revoke device tokens first:
                                    npm --prefix server run credential -- --list-tokens)
  $SERVER_DIR/credentials/
  $SERVER_DIR/chat-history.json and the other generated JSON state files
$( [ ! -d "$WORKSPACE_DIR" ] || printf '  %s/   (the isolated workspace and its files)\n' "$WORKSPACE_DIR")
$(server_log_files | sed 's/^/  /')

The CLI agents setup may have installed are untouched.
EOF
