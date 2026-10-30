#!/usr/bin/env bash
#
# Relay one-command setup.
#
# A menu that installs, reinstalls or uninstalls the backend, shows its status,
# and manages device tokens. Installing starts the backend with PM2, optionally
# opens a Cloudflare tunnel, then generates the credential QR that the Relay app
# scans. Run from the repo root (install.sh downloads a release and
# runs it with `install`, which skips the menu on a fresh host):
#
#   ./scripts/install/linux/setup.sh [install]
#
# Network modes:
#   1. No tunnel: for a VPS / box with a reachable public IP or domain.
#   2. Cloudflare Tunnel: named tunnel + stable hostname in your Cloudflare zone.
#   3. Cloudflare Quick Tunnel: temporary trycloudflare.com URL for fast trials.
#
set -euo pipefail

LINUX_ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$LINUX_ADAPTER_DIR/lib/common.sh"
ENV_EXAMPLE="$SERVER_DIR/.env.example"
TUNNEL_CONFIG_DIR="$SERVER_DIR/cloudflared-config"

credential() { (cd "$SERVER_DIR" && node scripts/create-credential.js "$@"); }

# Upsert KEY=VALUE into server/.env (pure bash; safe for URLs with / and :).
set_env() {
  local key="$1" val="$2" tmp
  [ -f "$ENV_FILE" ] || : >"$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    tmp="$(mktemp)"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "${key}="*) printf '%s=%s\n' "$key" "$val" ;;
        *) printf '%s\n' "$line" ;;
      esac
    done <"$ENV_FILE" >"$tmp"
    mv "$tmp" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
}

url_hostname() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%%:*}"
  printf '%s' "$value"
}

default_tunnel_name() {
  local short
  short="$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'machine')"
  short="$(printf '%s' "$short" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
  printf 'relay-%s' "${short:-machine}"
}

tunnel_id_for_name() {
  local name="$1"
  cloudflared tunnel list --name "$name" --output json 2>/dev/null | node -e '
const name = process.argv[1];
let input = "";
process.stdin.on("data", (chunk) => { input += chunk; });
process.stdin.on("end", () => {
  try {
    const list = JSON.parse(input);
    const item = Array.isArray(list)
      ? list.find((t) => t && t.name === name && !t.deletedAt)
      : null;
    if (item) process.stdout.write(String(item.id || item.ID || ""));
  } catch (_) {}
});
' "$name"
}

ensure_named_tunnel() {
  local name="$1" tunnel_id credentials_file
  if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
    c_info "Cloudflare login is required before creating a named tunnel." >&2
    cloudflared tunnel login >&2
  fi

  tunnel_id="$(tunnel_id_for_name "$name")"
  if [ -z "$tunnel_id" ]; then
    c_info "Creating Cloudflare Tunnel: $name" >&2
    cloudflared tunnel create "$name" >&2
    tunnel_id="$(tunnel_id_for_name "$name")"
  else
    c_info "Using existing Cloudflare Tunnel: $name ($tunnel_id)" >&2
  fi

  [ -n "$tunnel_id" ] || { c_err "Could not determine the Cloudflare Tunnel ID for $name."; exit 1; }
  credentials_file="$HOME/.cloudflared/${tunnel_id}.json"
  [ -f "$credentials_file" ] || {
    c_err "Missing tunnel credentials file: $credentials_file"
    c_err "If this tunnel was created on another machine, copy its credentials file here or create a new tunnel name."
    exit 1
  }
  printf '%s' "$tunnel_id"
}

ensure_tunnel_dns_route() {
  local tunnel_name="$1" hostname_value="$2" overwrite
  if cloudflared tunnel route dns "$tunnel_name" "$hostname_value"; then
    c_info "DNS route ensured: $hostname_value -> $tunnel_name"
    return 0
  fi

  c_warn "Cloudflare could not create the DNS route automatically."
  c_warn "This usually means an A, AAAA, or CNAME record already exists for $hostname_value."
  read -rp "${ASK}Overwrite the existing DNS record for $hostname_value? [y/N]: " overwrite
  case "$overwrite" in
    y | Y | yes | YES)
      cloudflared tunnel route dns --overwrite-dns "$tunnel_name" "$hostname_value"
      c_info "DNS route overwritten: $hostname_value -> $tunnel_name"
      ;;
    *)
      c_warn "Keeping the existing DNS record. The hostname may not reach this tunnel until you fix it in Cloudflare DNS."
      ;;
  esac
}

write_named_tunnel_config() {
  local tunnel_id="$1" hostname_value="$2" port="$3" config_file="$4"
  mkdir -p "$(dirname "$config_file")"
  cat >"$config_file" <<EOF
tunnel: $tunnel_id
credentials-file: $HOME/.cloudflared/$tunnel_id.json
ingress:
  - hostname: $hostname_value
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF
  chmod 600 "$config_file"
}

# ---- prerequisites ----
# Under sudo, PM2, the backend, its state files and agent CLI logins would all
# belong to root instead of the user who runs Relay.
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  c_err "Do not run setup with sudo. Run it as $SUDO_USER: ./scripts/install/linux/setup.sh"
  c_err "Setup asks for sudo itself when it installs system software."
  exit 1
fi
# Missing system tools are installed with apt-get (Debian/Ubuntu) after one
# confirmation; other distributions get the list to install by hand.
NODE_MIN_MAJOR=22
NODE_INSTALL_MAJOR=24 # the Node.js line the Windows backend bundle ships
APT_APPROVED=0

confirm_system_install() {
  if [ "$(id -u)" -ne 0 ] && ! need sudo; then
    c_err "Missing: $*. Installing it needs root or sudo."
    exit 1
  fi
  [ "$APT_APPROVED" -eq 1 ] && return
  read -rp "${ASK}Install missing system software ($*) with sudo? [Y/n]: " answer
  case "${answer:-y}" in
    [Yy]*) APT_APPROVED=1 ;;
    *) c_err "Missing: $*. Install it, then rerun setup."; exit 1 ;;
  esac
}

apt_install() {
  need apt-get || {
    c_err "Missing: $*. Install it with your package manager, then rerun setup."
    exit 1
  }
  confirm_system_install "$@"
  c_info "Installing $*..."
  as_root apt-get update
  as_root apt-get install -y "$@"
}

# A user-owned prefix (nvm) installs without sudo; a system one needs it.
npm_install_global() {
  if [ -w "$(npm prefix -g)" ]; then
    npm install -g "$@"
  else
    confirm_system_install "$@"
    as_root npm install -g "$@"
  fi
}

node_major() { node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0; }

install_prerequisites() {
if ! need node || [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
  if need node; then
    c_warn "Node.js $(node -v) is older than $NODE_MIN_MAJOR; installing Node.js $NODE_INSTALL_MAJOR."
  fi
  apt_install ca-certificates curl
  nodesource="$(mktemp)"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_INSTALL_MAJOR}.x" -o "$nodesource"
  as_root bash "$nodesource"
  rm -f "$nodesource"
  apt_install nodejs
  hash -r
  if [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
    c_err "Node.js >= $NODE_MIN_MAJOR is still not first on PATH ($(command -v node || echo 'node not found'))."
    c_err "Remove or update that older Node.js, then rerun setup."
    exit 1
  fi
fi
need npm || apt_install npm
if ! need pm2; then
  c_info "Installing pm2..."
  npm_install_global pm2
  hash -r
  need pm2 || { c_err "pm2 was installed but $(npm prefix -g)/bin is not on PATH."; exit 1; }
fi
need zip || apt_install zip
}

# cloudflared is not in the distribution repositories; Cloudflare publishes a
# .deb per architecture with each release.
ensure_cloudflared() {
  need cloudflared && return
  local arch deb
  if need dpkg && arch="$(dpkg --print-architecture)"; then
    apt_install ca-certificates curl
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

install_server_deps() {
cd "$SERVER_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  c_info "Created server/.env from .env.example"
fi
if [ ! -d node_modules ] ||
   ! node -e "require('node-pty')" >/dev/null 2>&1 ||
   [ ! -d node_modules/ws ]; then
  if ! node -e "require('node-pty')" >/dev/null 2>&1; then
    # Build tools for the Linux PTY addon.
    build_pkgs=()
    need python3 || build_pkgs+=(python3)
    need make || build_pkgs+=(make)
    need c++ || need g++ || build_pkgs+=(g++)
    [ "${#build_pkgs[@]}" -eq 0 ] || apt_install "${build_pkgs[@]}"
  fi
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
  need curl || apt_install ca-certificates curl
  # Hermes' installer clones its repository.
  [ "${AGENT_BINS[$i]}" != hermes ] || need git || apt_install git
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
    # A subshell, so declining sudo or a failed installer skips only this CLI
    # instead of exiting setup.
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
  if [ ! -f "$ROOT_DIR/app/shell/build/web/index.html" ]; then
    c_warn "This copy has no Web client (app/shell/build/web); the backend serves the API only."
    return
  fi
  read -rp "${ASK}Serve the Web client at the backend address? [Y/n]: " answer
  case "${answer:-y}" in
    [Yy]*) set_env RELAY_SERVE_WEB 1 ;;
    *) set_env RELAY_SERVE_WEB 0 ;;
  esac
}

install_backend() {
section "Step 1/5 · System software and server dependencies"
install_prerequisites
install_server_deps
section "Step 2/5 · Agent CLIs"
install_agent_clis
section "Step 3/5 · Web client"
choose_web

PORT_NUM="$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2 || true)"
PORT_NUM="${PORT_NUM:-8787}"

section "Step 4/5 · Network mode"
cat <<EOF
  1) No tunnel / direct public address
  2) Cloudflare Tunnel / named stable hostname
  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL
EOF
read -rp "${ASK}Network mode [1/2/3, default 3]: " NETWORK_MODE
NETWORK_MODE="${NETWORK_MODE:-3}"

case "$NETWORK_MODE" in
  1)
    # ---------- Direct mode (e.g. VPS with a public IP / domain) ----------
    c_info "Direct mode: the app connects straight to your address (no tunnel)."
    read -rp "${ASK}Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:${PORT_NUM}): " PUBLIC_URL
    [ -n "$PUBLIC_URL" ] || { c_err "A public address is required in direct mode."; exit 1; }
    case "$PUBLIC_URL" in
      http://* | https://*) ;;
      *) PUBLIC_URL="http://$PUBLIC_URL"; c_warn "No scheme given; assuming $PUBLIC_URL" ;;
    esac

    # Bind to all interfaces so the public IP/domain can reach the server.
    set_env HOST 0.0.0.0
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    set_env RELAY_TUNNEL_MODE none
    set_env CLOUDFLARED_BIN ""
    set_env CLOUDFLARED_ARGS ""

    c_info "Starting backend (PM2: $SERVER_PROC)..."
    pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js --only "$SERVER_PROC"
    pm2 save >/dev/null 2>&1 || true

    c_warn "Make sure port ${PORT_NUM} is open in your firewall / security group, and that"
    c_warn "${PUBLIC_URL} actually reaches this machine (directly or via a reverse proxy)."
    c_warn "For HTTPS, terminate TLS at a reverse proxy (nginx/Caddy) in front of port ${PORT_NUM}."

    section "Step 5/5 · Device credential (choose a password for the QR)"
    credential --url "$PUBLIC_URL"
    ;;
  2)
    # ---------- Cloudflare named tunnel ----------
    ensure_cloudflared
    c_info "Cloudflare Tunnel mode: stable hostname through a named tunnel."
    read -rp "${ASK}Public hostname for this backend (e.g. agent.example.com): " PUBLIC_HOSTNAME
    PUBLIC_HOSTNAME="$(url_hostname "$PUBLIC_HOSTNAME")"
    [ -n "$PUBLIC_HOSTNAME" ] || { c_err "A hostname is required for Cloudflare Tunnel mode."; exit 1; }
    DEFAULT_TUNNEL_NAME="$(default_tunnel_name)"
    read -rp "${ASK}Cloudflare tunnel name [$DEFAULT_TUNNEL_NAME]: " TUNNEL_NAME
    TUNNEL_NAME="${TUNNEL_NAME:-$DEFAULT_TUNNEL_NAME}"
    TUNNEL_NAME="$(printf '%s' "$TUNNEL_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_-]+/-/g; s/^-+|-+$//g')"
    [ -n "$TUNNEL_NAME" ] || { c_err "A tunnel name is required."; exit 1; }

    TUNNEL_ID="$(ensure_named_tunnel "$TUNNEL_NAME")"
    ensure_tunnel_dns_route "$TUNNEL_NAME" "$PUBLIC_HOSTNAME"

    PUBLIC_URL="https://$PUBLIC_HOSTNAME"
    CONFIG_FILE="$TUNNEL_CONFIG_DIR/${TUNNEL_NAME}.yml"
    write_named_tunnel_config "$TUNNEL_ID" "$PUBLIC_HOSTNAME" "$PORT_NUM" "$CONFIG_FILE"

    set_env HOST 127.0.0.1
    set_env PUBLIC_BASE_URL "$PUBLIC_URL"
    set_env RELAY_TUNNEL_MODE cloudflare
    set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
    set_env CLOUDFLARED_ARGS "tunnel --config $CONFIG_FILE run $TUNNEL_ID"

    c_info "Starting backend + Cloudflare Tunnel (PM2: $SERVER_PROC, $TUNNEL_PROC)..."
    pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js
    pm2 save >/dev/null 2>&1 || true

    section "Step 5/5 · Device credential (choose a password for the QR)"
    credential --url "$PUBLIC_URL"
    ;;
  3)
    # ---------- Cloudflare quick tunnel ----------
    ensure_cloudflared
    c_info "Quick Tunnel mode: exposing localhost:${PORT_NUM} via a temporary trycloudflare.com URL."

    # Tunnel reaches the server over localhost; keep it bound locally.
    set_env HOST 127.0.0.1
    set_env RELAY_TUNNEL_MODE quick
    set_env CLOUDFLARED_BIN "$(command -v cloudflared)"
    set_env CLOUDFLARED_ARGS "tunnel --url http://localhost:${PORT_NUM}"

    # Fresh logs so we read THIS run's tunnel URL, not a stale one.
    rm -f "$HOME/.pm2/logs/${TUNNEL_PROC}-error.log" \
          "$HOME/.pm2/logs/${TUNNEL_PROC}-out.log"

    c_info "Starting backend + tunnel (PM2: $SERVER_PROC, $TUNNEL_PROC)..."
    pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true
    pm2 start ecosystem.config.js
    pm2 save >/dev/null 2>&1 || true

    c_info "Waiting for the tunnel URL..."
    TUNNEL_URL=""
    for _ in $(seq 1 30); do
      TUNNEL_URL="$(grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com' \
        "$HOME/.pm2/logs/${TUNNEL_PROC}-error.log" \
        "$HOME/.pm2/logs/${TUNNEL_PROC}-out.log" 2>/dev/null | tail -1 || true)"
      [ -n "$TUNNEL_URL" ] && break
      sleep 1
    done
    if [ -n "$TUNNEL_URL" ]; then
      c_info "Tunnel URL: $TUNNEL_URL"
    else
      c_warn "Tunnel URL not visible yet; the credential step will retry detection."
    fi

    section "Step 5/5 · Device credential (choose a password for the QR)"
    credential
    ;;
  *)
    c_err "Invalid network mode: $NETWORK_MODE"
    exit 1
    ;;
esac

c_info "Done. In the app, tap \"Scan QR\", scan the QR above, and enter the password you just set."
c_info "Backend is managed by PM2 (pm2 list / pm2 logs / pm2 restart ${SERVER_PROC})."
c_info "Run ./scripts/install/linux/setup.sh again for status, tokens, reinstall or uninstall."
}

# ---- menu ----
installed() { need pm2 && pm2_has "$SERVER_PROC"; }

read_token_id() {
  credential --list-tokens
  read -rp "${ASK}Token id: " TOKEN_ID
  [ -n "$TOKEN_ID" ]
}

if [ "${1:-}" = install ] && ! installed; then
  install_backend
  exit 0
fi

while true; do
  section "Relay backend"
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
      if installed; then
        c_warn "Relay is already installed here. Choose 2 to reinstall."
        continue
      fi
      install_backend
      exit 0
      ;;
    2)
      read -rp "${ASK}Stop Relay, reinstall its dependencies and set up the network again? [y/N]: " answer
      case "$answer" in [Yy]*) ;; *) continue ;; esac
      if need pm2; then pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true; fi
      rm -rf "$SERVER_DIR/node_modules"
      install_backend
      exit 0
      ;;
    3)
      read -rp "${ASK}Stop and remove every Relay service, including the Web client? [y/N]: " answer
      case "$answer" in [Yy]*) exec "$LINUX_ADAPTER_DIR/uninstall.sh" ;; esac
      ;;
    4) "$LINUX_ADAPTER_DIR/status.sh" || true ;;
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
          read -rp "${ASK}Delete token $TOKEN_ID? Devices using it lose access. [y/N]: " answer
          case "$answer" in [Yy]*) credential --delete "$TOKEN_ID" || true ;; esac
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
