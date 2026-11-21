#!/usr/bin/env bash
#
# Relay setup for Linux and macOS, run as ./scripts/install/<linux|macos>/setup.sh.
#
# A menu that installs, reinstalls or uninstalls the backend, shows its status,
# installs agent CLIs and manages device tokens. Installing starts the backend
# (PM2 on Linux, a LaunchAgent on macOS), optionally opens a Cloudflare tunnel,
# then generates the credential QR that the Relay app scans. install.sh runs it
# with `install`, which skips the menu on a fresh host.
#
# Network modes:
#   1. No tunnel: for a VPS / box with a reachable public IP or domain.
#   2. Cloudflare Tunnel: named tunnel + stable hostname in your Cloudflare zone.
#   3. Cloudflare Quick Tunnel: temporary trycloudflare.com URL for fast trials.
#   4. Tailscale: this machine's tailnet IP; falls back to the menu without one.
#
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

refuse_sudo setup.sh

install_server_deps() {
  ensure_env_file
  cd "$SERVER_DIR"
  if [ ! -d node_modules ] ||
     ! node -e "require('node-pty')" >/dev/null 2>&1 ||
     [ ! -d node_modules/ws ]; then
    node -e "require('node-pty')" >/dev/null 2>&1 || ensure_pty_build_tools
    c_info "Installing server dependencies..."
    # A release installs exactly its lock file, without the development tools
    # a source checkout keeps for lint and tests.
    if [ -e "$ROOT_DIR/.git" ]; then npm install; else npm ci --omit=dev; fi
    if ! node -e "require('node-pty')" >/dev/null 2>&1; then
      ensure_pty_build_tools
      npm rebuild node-pty
    fi
    node -e "require('node-pty')"
  fi
}

# ---- agent CLIs ----
# The agents, their labels, sign-in commands and install state come from the
# backend (server/scripts/setup-status.js), so this menu sees what Relay sees.
# Only each CLI's official installer lives here. Relay never signs an agent in:
# the login command is printed for the user.
agent_installer() {
  case "$1" in
    claude) printf '%s' https://claude.ai/install.sh ;;
    cursor) printf '%s' https://cursor.com/install ;;
    opencode) printf '%s' https://opencode.ai/install ;;
    agy) printf '%s' https://antigravity.google/cli/install.sh ;;
    hermes) printf '%s' https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh ;;
  esac
}

# key<TAB>label<TAB>installed (1/0)<TAB>login, one line per agent.
agent_rows() { (cd "$SERVER_DIR" && node scripts/setup-status.js --agents); }

install_agent_cli() {
  local key="$1" label="$2" script
  c_info "Installing $label..."
  if [ "$key" = codex ]; then
    need npm || { c_warn "Codex installs with npm, which is missing. Choose 1 to install Relay first."; return 1; }
    npm_install_global @openai/codex
    return
  fi
  need curl || system_install curl
  # Hermes' installer clones its repository.
  [ "$key" != hermes ] || need git || system_install git
  # Saved to a file rather than piped, so an installer that asks questions
  # still reads them from this terminal.
  script="$(mktemp)"
  trap "rm -f '$script'" EXIT
  curl -fsSL "$(agent_installer "$key")" -o "$script" && bash "$script"
}

install_agent_clis() {
  local rows n picks key label installed login i missing=() added=()
  local keys=() labels=() logins=()
  rows="$(agent_rows)"
  i=0
  while IFS=$'\t' read -r key label installed login; do
    keys+=("$key"); labels+=("$label"); logins+=("$login")
    i=$((i + 1))
    if [ "$installed" = 1 ]; then
      printf '  %d) %-12s \033[32m✔ installed\033[0m\n' "$i" "$label"
    else
      printf '  %d) %-12s \033[2m✘ not installed\033[0m\n' "$i" "$label"
      missing+=("$i")
    fi
  done <<<"$rows"
  if [ "${#missing[@]}" -eq 0 ]; then
    c_info "Every agent CLI is installed."
    return
  fi
  read -rp "${ASK}Install which? Numbers separated by spaces, a = all missing, Enter = skip: " picks || true
  [ "$picks" != a ] || picks="${missing[*]}"
  for n in $picks; do
    case " ${missing[*]} " in
      *" $n "*) ;;
      *)
        if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#keys[@]}" ]; then
          c_warn "${labels[$((n - 1))]} is already installed."
        else
          c_warn "Skipping invalid choice: $n"
        fi
        continue
        ;;
    esac
    i=$((n - 1))
    # A subshell, so declining a system install or a failed installer skips
    # only this CLI instead of exiting setup.
    (install_agent_cli "${keys[$i]}" "${labels[$i]}") || true
    hash -r
    if [ "$(agent_rows | awk -F '\t' -v key="${keys[$i]}" '$1 == key { print $3 }')" = 1 ]; then
      added+=("$i")
    else
      c_warn "${labels[$i]} did not install. Install it by hand later; Relay finds it without a restart."
    fi
  done
  [ "${#added[@]}" -gt 0 ] || return 0
  c_info "Sign in to each new CLI on this machine (open a new terminal if a command is not found):"
  for i in "${added[@]}"; do
    printf '  %-12s %s\n' "${labels[$i]}" "${logins[$i]}"
  done
  printf '  Relay picks them up within a minute; no restart needed.\n'
}

# Release packages ship app/shell/build/web; RELAY_SERVE_WEB=0 keeps it unserved.
choose_web() {
  local answer
  if [ ! -f "$WEB_DIR/index.html" ]; then
    c_warn "This copy has no Web client (app/shell/build/web); the backend serves the API only."
    return
  fi
  read -rp "${ASK}Serve the Web client at the backend address? [Y/n]: " answer
  case "${answer:-y}" in
    [Yy]*) set_env RELAY_SERVE_WEB 1 ;;
    *) set_env RELAY_SERVE_WEB 0 ;;
  esac
}

# Isolated confines workdirs, the file API and the agents' permission tiers to
# <install>/workspace (server/lib/workdir.js enforces it); open leaves every
# file this user can reach. Rerunning setup defaults to the current choice.
choose_file_access() {
  local current=1 answer
  [ -z "$(get_env RELAY_WORKSPACE_ROOT)" ] || current=2
  cat <<EOF
  1) Open: agents and the file browser reach every file this $PLATFORM_LABEL user can
  2) Isolated: workspaces and the file browser stay inside $WORKSPACE_DIR
EOF
  read -rp "${ASK}File access [1/2, default $current]: " answer
  case "${answer:-$current}" in
    1)
      set_env RELAY_WORKSPACE_ROOT ""
      c_info "Open: agents and the file browser reach every file this $PLATFORM_LABEL user can."
      ;;
    2)
      mkdir -p "$WORKSPACE_DIR"
      set_env RELAY_WORKSPACE_ROOT "$WORKSPACE_DIR"
      c_info "Isolated: workspaces and the file browser stay inside $WORKSPACE_DIR"
      ;;
    *) c_err "Invalid file access choice: $answer"; exit 1 ;;
  esac
}

clear_tunnel_logs() {
  local file
  while IFS= read -r file; do rm -f "$file"; done < <(tunnel_log_files)
}

# The Browser page drives a host Chrome, Chromium or Edge. Without one the rest
# of Relay works, so this only reminds.
check_browser() {
  local found
  if found="$(cd "$SERVER_DIR" && node scripts/check-browser.js 2>/dev/null)"; then
    c_info "Browser page will use: $found"
  else
    c_warn "No Chrome, Chromium or Edge found. Relay's Browser page needs one; everything else works without it."
    c_warn "$(browser_install_hint)"
    c_warn "Relay finds it once installed, without a restart. Or set RELAY_BROWSER in server/.env to its path, then restart Relay."
  fi
}

# This machine's tailnet IPv4, or failure when Tailscale is missing or not up.
# The macOS app ships its CLI inside the bundle rather than on PATH.
tailscale_ipv4() {
  local bin raw ip
  bin="$(command -v tailscale 2>/dev/null || true)"
  if [ -z "$bin" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    bin=/Applications/Tailscale.app/Contents/MacOS/Tailscale
  fi
  [ -n "$bin" ] || return 1
  raw="$("$bin" ip -4 2>/dev/null)" || return 1
  ip="${raw%%$'\n'*}"
  ip="${ip%$'\r'}"
  local octet='(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])'
  local tailnet="^100[.](6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])[.]${octet}[.]${octet}$"
  [[ "$ip" =~ $tailnet ]] || return 1
  printf '%s' "$ip"
}

install_backend() {
  local port answer default_mode mode public_url tailscale_ip hostname_value tunnel_name answer_name tunnel_id config_file quick_url
  section "Step 1/6 · System software and server dependencies"
  install_prerequisites
  install_server_deps
  check_browser
  section "Step 2/6 · Agent CLIs"
  install_agent_clis
  section "Step 3/6 · Web client"
  choose_web
  section "Step 4/6 · File access"
  choose_file_access

  section "Step 5/6 · Network mode"
  port="$(backend_port)"
  read -rp "${ASK}Backend port [$port]: " answer
  port="${answer:-$port}"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] ||
    { c_err "Port must be between 1 and 65535."; exit 1; }
  set_env PORT "$port"
  # A Quick Tunnel's address changes on every restart; a tailnet's does not.
  default_mode=3
  ! tailscale_ipv4 >/dev/null || default_mode=4
  while :; do
    cat <<EOF
  1) No tunnel / direct public address
  2) Cloudflare Tunnel / named stable hostname
  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL
  4) Tailscale / this machine's Tailscale IP, reachable from your tailnet
EOF
    read -rp "${ASK}Network mode [1/2/3/4, default $default_mode]: " mode
    mode="${mode:-$default_mode}"
    [ "$mode" = 4 ] || break
    tailscale_ip="$(tailscale_ipv4)" && break
    c_warn "Tailscale is not installed here, or this machine is not connected to a tailnet."
    c_warn "Install it from https://tailscale.com/download and run \"tailscale up\", or choose another mode."
  done

  case "$mode" in
    1)
      c_info "Direct mode: the app connects straight to your address (no tunnel)."
      read -rp "${ASK}Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:${port}): " public_url
      [ -n "$public_url" ] || { c_err "A public address is required in direct mode."; exit 1; }
      case "$public_url" in
        http://* | https://*) ;;
        *) public_url="http://$public_url"; c_warn "No scheme given; assuming $public_url" ;;
      esac
      node -e '
const u = new URL(process.argv[1]);
if (!/^https?:$/.test(u.protocol) || u.username || u.password || u.search || u.hash) process.exit(1);
' "$public_url" 2>/dev/null || { c_err "Enter an HTTP(S) address without credentials, query or fragment."; exit 1; }
      # Bind to all interfaces so the public IP/domain can reach the server.
      set_env HOST 0.0.0.0
      set_env PUBLIC_BASE_URL "$public_url"
      set_env RELAY_TUNNEL_MODE none
      set_env CLOUDFLARED_BIN ""
      set_env CLOUDFLARED_ARGS ""

      c_info "Starting the backend..."
      svc_start fresh
      c_warn "Make sure port ${port} is open in your firewall / security group, and that"
      c_warn "${public_url} actually reaches this machine (directly or via a reverse proxy)."
      c_warn "For HTTPS, terminate TLS at a reverse proxy (nginx/Caddy) in front of port ${port}."
      ;;
    4)
      public_url="http://${tailscale_ip}:${port}"
      c_info "Tailscale mode: devices on your tailnet connect to $public_url (WireGuard-encrypted)."
      if [ -f "$WEB_DIR/index.html" ] && [ "$(get_env RELAY_SERVE_WEB)" != 0 ]; then
        c_info "Native apps can use $public_url. Relay Web needs a trusted HTTPS origin to store credentials."
        c_info "For Web, configure an HTTPS reverse proxy to $public_url and enter its hostname."
        read -rp "${ASK}HTTPS proxy hostname (Enter for native apps only): " hostname_value
        if [ -n "$hostname_value" ]; then
          [[ "$hostname_value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { c_err "Enter a hostname without a scheme, port or path."; return 1; }
          public_url="https://$hostname_value"
        else
          set_env RELAY_SERVE_WEB 0
        fi
      fi
      set_env HOST "$tailscale_ip"
      set_env PUBLIC_BASE_URL "$public_url"
      set_env RELAY_TUNNEL_MODE none
      set_env CLOUDFLARED_BIN ""
      set_env CLOUDFLARED_ARGS ""

      c_info "Starting the backend..."
      svc_start fresh
      c_warn "Install Tailscale on each phone or computer that uses Relay and sign in to the same tailnet."
      ;;
    2)
      ensure_cloudflared
      c_info "Cloudflare Tunnel mode: stable hostname through a named tunnel."
      read -rp "${ASK}Public hostname for this backend (e.g. agent.example.com): " hostname_value
      hostname_value="$(url_hostname "$hostname_value")"
      [ -n "$hostname_value" ] || { c_err "A hostname is required for Cloudflare Tunnel mode."; exit 1; }
      tunnel_name="$(default_tunnel_name)"
      read -rp "${ASK}Cloudflare tunnel name [$tunnel_name]: " answer_name
      tunnel_name="${answer_name:-$tunnel_name}"
      tunnel_name="$(printf '%s' "$tunnel_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
      [ -n "$tunnel_name" ] || { c_err "A tunnel name is required."; exit 1; }

      tunnel_id="$(ensure_named_tunnel "$tunnel_name")"
      ensure_tunnel_dns_route "$tunnel_name" "$hostname_value"

      public_url="https://$hostname_value"
      config_file="$TUNNEL_CONFIG_DIR/${tunnel_name}.yml"
      write_named_tunnel_config "$tunnel_id" "$hostname_value" "$port" "$config_file"

      set_env HOST 127.0.0.1
      set_env PUBLIC_BASE_URL "$public_url"
      set_env RELAY_TUNNEL_MODE cloudflare
      set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
      set_env CLOUDFLARED_ARGS "tunnel --config $config_file run $tunnel_id"

      c_info "Starting the backend and Cloudflare Tunnel..."
      svc_start fresh
      ;;
    3)
      ensure_cloudflared
      c_info "Quick Tunnel mode: exposing 127.0.0.1:${port} via a temporary trycloudflare.com URL."
      # The tunnel reaches the server over loopback; keep it bound locally.
      set_env HOST 127.0.0.1
      # An address from an earlier mode must not stand in for the tunnel's.
      set_env PUBLIC_BASE_URL ""
      set_env RELAY_TUNNEL_MODE quick
      set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
      set_env CLOUDFLARED_ARGS "tunnel --url http://127.0.0.1:${port}"
      # Fresh logs so the URL read below is this run's, not a stale one.
      clear_tunnel_logs

      c_info "Starting the backend and Quick Tunnel..."
      svc_start fresh

      c_info "Waiting for the tunnel URL..."
      quick_url=""
      for _ in $(seq 1 45); do
        quick_url="$(latest_quick_url)"
        [ -n "$quick_url" ] && break
        sleep 1
      done
      if [ -n "$quick_url" ]; then
        c_info "Tunnel URL: $quick_url"
        public_url="$quick_url"
      else
        c_warn "Tunnel URL not visible yet; the credential step will retry detection."
        public_url=""
      fi
      ;;
    *)
      c_err "Invalid network mode: $mode"
      exit 1
      ;;
  esac

  section "Step 6/6 · Device credential (choose a password for the QR)"
  if [ -n "$public_url" ]; then credential --url "$public_url"; else credential; fi

  c_info "Done. In the app, tap \"Scan QR\", scan the QR above, and enter the password you just set."
  if [ "$mode" = 3 ]; then
    c_warn "The trycloudflare.com address changes whenever the tunnel restarts (a reboot, a crash, a reinstall)."
    c_warn "Each device then needs a new QR: $(script_path setup.sh), choice 9. For daily use, choose Cloudflare Tunnel (2) or Tailscale (4)."
  fi
  c_info "$(service_hint)"
  c_info "Run $(script_path setup.sh) again for status, tokens, reinstall or uninstall."
}

# ---- menu ----
read_token_id() {
  credential --list-tokens
  read -rp "${ASK}Token id: " TOKEN_ID
  [ -n "$TOKEN_ID" ]
}

if [ "${1:-}" = install ] && ! svc_registered server; then
  install_backend
  exit 0
fi
installed_elsewhere || true

while true; do
  section "Relay backend · $PLATFORM_LABEL"
  cat <<'MENU'
  1) Install
  2) Reinstall (keeps tokens, chats and settings)
  3) Uninstall all services
  4) Service status (address, agents, tokens)
  5) Install agent CLIs (Claude Code, Codex, Cursor, OpenCode, Antigravity, Hermes)
  6) Create a new token
  7) Delete a token
  8) List tokens
  9) Show a token's credential QR again
  0) Exit
MENU
  read -rp "${ASK}Choose [0-9]: " CHOICE || exit 0
  case "$CHOICE" in
    1)
      if svc_registered server; then
        installed_elsewhere || c_warn "Relay is already installed here. Choose 2 to reinstall."
        continue
      fi
      install_backend
      exit 0
      ;;
    2)
      installed_elsewhere || true
      ask_no "Stop Relay, reinstall its dependencies and set up the network again?" || continue
      svc_remove >/dev/null
      rm -rf "$SERVER_DIR/node_modules"
      install_backend
      exit 0
      ;;
    3)
      if ask_no "Stop and remove every Relay service, including the Web client?"; then
        exec "$UNIX_DIR/uninstall.sh"
      fi
      ;;
    4) "$UNIX_DIR/status.sh" || true ;;
    5 | 6 | 7 | 8 | 9)
      if [ ! -f "$ENV_FILE" ] || [ ! -d "$SERVER_DIR/node_modules" ]; then
        c_warn "Relay is not installed here yet. Choose 1 first."
        continue
      fi
      case "$CHOICE" in
        5)
          section "Agent CLIs"
          install_agent_clis
          ;;
        6)
          section "Create a token"
          read -rp "${ASK}Label for the device that will use it [$(hostname)]: " LABEL
          credential --label "${LABEL:-$(hostname)}" || true
          ;;
        7)
          section "Delete a token"
          read_token_id || continue
          if ask_no "Delete token $TOKEN_ID? Devices using it lose access."; then
            credential --delete "$TOKEN_ID" || true
          fi
          ;;
        8) credential --list-tokens ;;
        9)
          section "Show a token's credential QR again"
          if read_token_id; then credential --show "$TOKEN_ID" || true; fi ;;
      esac
      ;;
    0) exit 0 ;;
    *) c_warn "Invalid choice: $CHOICE" ;;
  esac
done
