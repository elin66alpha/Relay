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
    npm install
    if ! node -e "require('node-pty')" >/dev/null 2>&1; then
      npm rebuild node-pty
    fi
    node -e "require('node-pty')"
  fi
}

# ---- agent CLIs ----
# Each CLI's official installer. Codex ships on npm; the rest publish a script.
# Relay never signs an agent in: the login command is printed for the user.
AGENT_LABELS=("Claude Code" "Codex" "Cursor" "OpenCode" "Hermes")
AGENT_BINS=(claude codex agent opencode hermes)
AGENT_SCRIPTS=(
  "https://claude.ai/install.sh"
  ""
  "https://cursor.com/install"
  "https://opencode.ai/install"
  "https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
)
AGENT_LOGINS=("claude" "codex login --device-auth" "agent login" "opencode auth login" "hermes setup")

# The same places the backend looks (server/lib/cli-paths.js): PATH, then the
# per-user dirs the installers use, which this shell's PATH may lack.
agent_cli_installed() {
  need "$1" || [ -x "$HOME/.local/bin/$1" ] ||
    { [ "$1" = opencode ] && [ -x "$HOME/.opencode/bin/opencode" ]; }
}

install_agent_cli() {
  local i="$1" script
  c_info "Installing ${AGENT_LABELS[$i]}..."
  if [ -z "${AGENT_SCRIPTS[$i]}" ]; then
    need npm || { c_warn "Codex installs with npm, which is missing. Choose 1 to install Relay first."; return 1; }
    npm_install_global @openai/codex
    return
  fi
  need curl || system_install curl
  # Hermes' installer clones its repository.
  [ "${AGENT_BINS[$i]}" != hermes ] || need git || system_install git
  # Saved to a file rather than piped, so an installer that asks questions
  # still reads them from this terminal.
  script="$(mktemp)"
  trap "rm -f '$script'" EXIT
  curl -fsSL "${AGENT_SCRIPTS[$i]}" -o "$script" && bash "$script"
}

install_agent_clis() {
  local i n picks missing=() added=()
  for i in "${!AGENT_BINS[@]}"; do
    if agent_cli_installed "${AGENT_BINS[$i]}"; then
      printf '  %d) %-12s \033[32m✔ installed\033[0m\n' "$((i + 1))" "${AGENT_LABELS[$i]}"
    else
      printf '  %d) %-12s \033[2m✘ not installed\033[0m\n' "$((i + 1))" "${AGENT_LABELS[$i]}"
      missing+=("$((i + 1))")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    c_info "All five agent CLIs are installed."
    return
  fi
  read -rp "${ASK}Install which? Numbers separated by spaces, a = all missing, Enter = skip: " picks
  [ "$picks" != a ] || picks="${missing[*]}"
  for n in $picks; do
    case "$n" in [1-5]) ;; *) c_warn "Skipping invalid choice: $n"; continue ;; esac
    i=$((n - 1))
    if agent_cli_installed "${AGENT_BINS[$i]}"; then
      c_warn "${AGENT_LABELS[$i]} is already installed."
      continue
    fi
    # A subshell, so declining a system install or a failed installer skips
    # only this CLI instead of exiting setup.
    (install_agent_cli "$i") || true
    hash -r
    if agent_cli_installed "${AGENT_BINS[$i]}"; then
      added+=("$i")
    else
      c_warn "${AGENT_LABELS[$i]} did not install. Install it by hand later; Relay finds it without a restart."
    fi
  done
  [ "${#added[@]}" -gt 0 ] || return 0
  c_info "Sign in to each new CLI on this machine (open a new terminal if a command is not found):"
  for i in "${added[@]}"; do
    printf '  %-12s %s\n' "${AGENT_LABELS[$i]}" "${AGENT_LOGINS[$i]}"
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

install_backend() {
  local port mode public_url hostname_value tunnel_name answer_name tunnel_id config_file quick_url
  section "Step 1/6 · System software and server dependencies"
  install_prerequisites
  install_server_deps
  section "Step 2/6 · Agent CLIs"
  install_agent_clis
  section "Step 3/6 · Web client"
  choose_web
  section "Step 4/6 · File access"
  choose_file_access

  port="$(backend_port)"

  section "Step 5/6 · Network mode"
  cat <<EOF
  1) No tunnel / direct public address
  2) Cloudflare Tunnel / named stable hostname
  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL
EOF
  read -rp "${ASK}Network mode [1/2/3, default 3]: " mode
  mode="${mode:-3}"

  case "$mode" in
    1)
      c_info "Direct mode: the app connects straight to your address (no tunnel)."
      read -rp "${ASK}Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:${port}): " public_url
      [ -n "$public_url" ] || { c_err "A public address is required in direct mode."; exit 1; }
      case "$public_url" in
        http://* | https://*) ;;
        *) public_url="http://$public_url"; c_warn "No scheme given; assuming $public_url" ;;
      esac
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

while true; do
  section "Relay backend · $PLATFORM_LABEL"
  cat <<'MENU'
  1) Install
  2) Reinstall (keeps tokens, chats and settings)
  3) Uninstall all services
  4) Service status (address, agents, tokens)
  5) Install agent CLIs (Claude Code, Codex, Cursor, OpenCode, Hermes)
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
        c_warn "Relay is already installed here. Choose 2 to reinstall."
        continue
      fi
      install_backend
      exit 0
      ;;
    2)
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
    5)
      section "Agent CLIs"
      install_agent_clis
      ;;
    6 | 7 | 8 | 9)
      if [ ! -f "$ENV_FILE" ] || [ ! -d "$SERVER_DIR/node_modules" ]; then
        c_warn "Relay is not installed here yet. Choose 1 first."
        continue
      fi
      case "$CHOICE" in
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
