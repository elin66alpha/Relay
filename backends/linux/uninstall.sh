#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

ask_no() {
  local answer
  read -rp "$1 [y/N]: " answer
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

if need pm2; then
  c_info "Removing Relay PM2 processes"
  for proc in "$TUNNEL_PROC" "$SERVER_PROC"; do
    if pm2_has "$proc"; then
      pm2 delete "$proc" >/dev/null
      printf '  deleted %s\n' "$proc"
    else
      printf '  %s was not registered\n' "$proc"
    fi
  done
  pm2 save >/dev/null 2>&1 || true
fi

if [ -d "$ROOT_DIR/build/web" ]; then
  rm -rf "$ROOT_DIR/build/web"
  c_info "Removed the Web client ($ROOT_DIR/build/web)."
fi

if [ "$(tunnel_mode)" = "cloudflare" ] && need cloudflared; then
  config_file="$(get_env CLOUDFLARED_ARGS | sed -nE 's/.*--config ([^ ]+).*/\1/p')"
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
if need pm2; then
  others="$(pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(_){console.log(0)}})')"
  if [ "${others:-0}" -gt 0 ]; then
    c_warn "PM2 still manages $others other process(es); keeping PM2."
  elif ask_no "Remove PM2?"; then
    pm2 kill >/dev/null 2>&1 || true
    if [ -w "$(npm prefix -g)" ]; then npm uninstall -g pm2; else as_root npm uninstall -g pm2; fi
  fi
fi
if need cloudflared && ask_no "Remove cloudflared?"; then
  if dpkg -s cloudflared >/dev/null 2>&1; then
    as_root dpkg -r cloudflared
  else
    c_warn "cloudflared at $(command -v cloudflared) was not installed by a package; remove it by hand."
  fi
fi
if need node && ask_no "Remove Node.js? Other programs on this host may need it."; then
  if dpkg -s nodejs >/dev/null 2>&1; then
    as_root apt-get remove -y nodejs
  else
    c_warn "Node.js at $(command -v node) was not installed by apt (nvm, a tarball, ...); remove it the same way you installed it."
  fi
fi

c_info "Uninstalled."
cat <<EOF
Backend data was left in place on purpose. Delete it yourself if you are
retiring this host:

  $SERVER_DIR/.env
  $SERVER_DIR/tokens.json          (revoke device tokens first:
                                    npm --prefix server run credential -- --list-tokens)
  $SERVER_DIR/credentials/
  $SERVER_DIR/chat-history.json and the other generated JSON state files
  $PM2_LOG_DIR/$SERVER_PROC-*.log

The CLI agents and build tools setup may have installed (zip, python3, make,
g++) are untouched.
EOF
