#!/usr/bin/env bash
# Linux adapter for lib/common.sh: apt-get installs system software
# (Debian/Ubuntu; other distributions get the list to install by hand) and PM2
# runs the services defined in server/ecosystem.config.js.

PLATFORM_LABEL="Linux"
NODE_INSTALL_MAJOR=24 # the Node.js line the Windows backend bundle ships
SERVER_PROC="relay-server"
TUNNEL_PROC="relay-tunnel"
PM2_LOG_DIR="$HOME/.pm2/logs"

system_install() {
  local pkgs=("$@")
  need apt-get || {
    c_err "Missing: $*. Install it with your package manager, then rerun setup."
    exit 1
  }
  require_sudo "$@"
  # Downloads below need the CA bundle that minimal images leave out.
  case " $* " in *" curl "*) pkgs=(ca-certificates "${pkgs[@]}") ;; esac
  confirm_system_install sudo "$@"
  c_info "Installing $*..."
  as_root apt-get update
  as_root apt-get install -y "${pkgs[@]}"
}

install_prerequisites() {
  local nodesource
  if ! need node || [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
    if need node; then
      c_warn "Node.js $(node -v) is older than $NODE_MIN_MAJOR; installing Node.js $NODE_INSTALL_MAJOR."
    fi
    need apt-get || {
      c_err "Node.js $NODE_MIN_MAJOR+ is required. Install it with your package manager (https://nodejs.org/en/download), then rerun setup."
      exit 1
    }
    # The one confirmation names what is installed, not the curl used to fetch it.
    require_sudo nodejs
    confirm_system_install sudo "Node.js $NODE_INSTALL_MAJOR from the NodeSource apt repository"
    need curl || system_install curl
    nodesource="$(mktemp)"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_INSTALL_MAJOR}.x" -o "$nodesource"
    as_root bash "$nodesource"
    rm -f "$nodesource"
    system_install nodejs
    hash -r
    if [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
      c_err "Node.js >= $NODE_MIN_MAJOR is still not first on PATH ($(command -v node || echo 'node not found'))."
      c_err "Remove or update that older Node.js, then rerun setup."
      exit 1
    fi
  fi
  need npm || system_install npm
  if ! need pm2; then
    c_info "Installing pm2..."
    npm_install_global pm2
    hash -r
    need pm2 || { c_err "pm2 was installed but $(npm prefix -g)/bin is not on PATH."; exit 1; }
  fi
  need zip || system_install zip
}

ensure_pty_build_tools() {
  local pkgs=()
  need python3 || pkgs+=(python3)
  need make || pkgs+=(make)
  need c++ || need g++ || pkgs+=(g++)
  [ "${#pkgs[@]}" -eq 0 ] || system_install "${pkgs[@]}"
}

# cloudflared is not in the distribution repositories; Cloudflare publishes a
# .deb per architecture with each release.
ensure_cloudflared() {
  need cloudflared && return
  local arch deb
  if need dpkg && arch="$(dpkg --print-architecture)"; then
    require_sudo cloudflared
    confirm_system_install sudo "cloudflared from Cloudflare's .deb"
    need curl || system_install curl
    deb="$(mktemp --suffix=.deb)"
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" -o "$deb"
    as_root dpkg -i "$deb"
    rm -f "$deb"
    hash -r
  fi
  need cloudflared || {
    c_err "cloudflared is required for Cloudflare tunnel modes."
    c_err "Install: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
    exit 1
  }
}

require_pm2() {
  need pm2 || { c_err "pm2 is required. Install it with: npm install -g pm2"; exit 1; }
}

pm2_has() { pm2 describe "$1" >/dev/null 2>&1; }

proc_name() { if [ "$1" = tunnel ]; then printf '%s' "$TUNNEL_PROC"; else printf '%s' "$SERVER_PROC"; fi; }

svc_registered() { need pm2 && pm2_has "$(proc_name "$1")"; }

# ecosystem.config.js omits the tunnel app when RELAY_TUNNEL_MODE=none, and
# --update-env re-reads server/.env for processes that already exist.
svc_start() {
  require_pm2
  [ "${1:-}" != fresh ] || pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true
  (cd "$SERVER_DIR" && pm2 start ecosystem.config.js --update-env)
  pm2 save >/dev/null 2>&1 || true
  [ "${1:-}" != fresh ] || ensure_pm2_boot
}

# The backend alone, re-read from ecosystem.config.js and server/.env. The
# tunnel keeps running, so a Quick Tunnel keeps its URL.
svc_restart_server() {
  require_pm2
  pm2 delete "$SERVER_PROC" >/dev/null 2>&1 || true
  (cd "$SERVER_DIR" && pm2 start ecosystem.config.js --only "$SERVER_PROC" --update-env)
  pm2 save >/dev/null 2>&1 || true
}

# pm2 save records the processes; PM2's systemd unit restores them at boot.
ensure_pm2_boot() {
  local user answer
  user="$(id -un)"
  if ! need systemctl || [ ! -d /run/systemd/system ]; then
    c_warn "This host has no systemd, so Relay does not start after a reboot. Run $(script_path start.sh) after each boot."
    return 0
  fi
  systemctl is-enabled "pm2-$user" >/dev/null 2>&1 && return 0
  if [ "$(id -u)" -ne 0 ] && ! need sudo; then
    c_warn "Starting Relay at boot needs sudo. Without it, run $(script_path start.sh) after each reboot."
    return 0
  fi
  read -rp "${ASK}Start Relay when this machine boots (a pm2-$user systemd service, needs sudo)? [Y/n]: " answer || true
  case "${answer:-y}" in
    [Yy]*) ;;
    *) c_warn "Relay will not start after a reboot. Run $(script_path start.sh) after each boot."; return 0 ;;
  esac
  as_root env PATH="$PATH" "$(command -v pm2)" startup systemd -u "$user" --hp "$HOME" >/dev/null ||
    c_warn "Could not register the boot service. Run pm2 startup and follow its instructions."
}

# The installation the registered backend runs from, or nothing.
svc_root() {
  need pm2 || return 0
  pm2 jlist 2>/dev/null | node -e '
let s = "";
process.stdin.on("data", (d) => { s += d; }).on("end", () => {
  try {
    const app = JSON.parse(s).find((p) => p.name === process.argv[1]);
    if (app && app.pm2_env && app.pm2_env.pm_cwd) process.stdout.write(require("path").dirname(app.pm2_env.pm_cwd));
  } catch (_) {}
});
' "$SERVER_PROC"
}

# The tunnel stops first so it stops advertising a backend that is going away.
svc_stop() {
  local proc
  require_pm2
  for proc in "$TUNNEL_PROC" "$SERVER_PROC"; do
    if pm2_has "$proc"; then
      c_info "Stopping $proc"
      pm2 stop "$proc" >/dev/null
    fi
  done
  pm2 save >/dev/null 2>&1 || true
}

svc_remove() {
  local proc
  need pm2 || return 0
  for proc in "$TUNNEL_PROC" "$SERVER_PROC"; do
    if pm2_has "$proc"; then
      pm2 delete "$proc" >/dev/null
      printf '  removed %s\n' "$proc"
    fi
  done
  pm2 save >/dev/null 2>&1 || true
}

browser_install_hint() {
  printf '%s' 'Install one, for example: sudo snap install chromium, or Google Chrome from https://www.google.com/chrome/'
}

svc_summary() { require_pm2; pm2 list; }

server_log_files() { printf '%s\n' "$PM2_LOG_DIR/$SERVER_PROC-out.log" "$PM2_LOG_DIR/$SERVER_PROC-error.log"; }
tunnel_log_files() { printf '%s\n' "$PM2_LOG_DIR/$TUNNEL_PROC-error.log" "$PM2_LOG_DIR/$TUNNEL_PROC-out.log"; }

service_hint() {
  printf 'Backend is managed by PM2 (pm2 list / pm2 logs %s / pm2 restart %s).\n' "$SERVER_PROC" "$SERVER_PROC"
}

remove_system_software() {
  local others
  if need pm2; then
    others="$(pm2 jlist 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).length)}catch(_){console.log(0)}})')"
    if [ "${others:-0}" -gt 0 ]; then
      c_warn "PM2 still manages $others other process(es); keeping PM2."
    elif ask_no "Remove PM2?"; then
      if need systemctl && systemctl is-enabled "pm2-$(id -un)" >/dev/null 2>&1; then
        as_root env PATH="$PATH" "$(command -v pm2)" unstartup systemd -u "$(id -un)" --hp "$HOME" >/dev/null || true
      fi
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
  printf 'Build tools setup may have installed (zip, python3, make, g++) are untouched.\n'
}
