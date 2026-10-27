#!/usr/bin/env bash
#
# Relay one-command setup.
#
# A menu that installs, reinstalls or uninstalls the backend, shows its status,
# and manages device tokens. Installing starts the backend with PM2, optionally
# opens a Cloudflare tunnel, then generates the credential QR that the Relay app
# scans. Run from the repo root:
#
#   ./backends/linux/setup.sh
#
# Network modes:
#   1. No tunnel: for a VPS / box with a reachable public IP or domain.
#   2. Cloudflare Tunnel: named tunnel + stable hostname in your Cloudflare zone.
#   3. Cloudflare Quick Tunnel: temporary trycloudflare.com URL for fast trials.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LINUX_ADAPTER_DIR="$ROOT_DIR/backends/linux"
# shellcheck source=../backends/linux/lib/common.sh
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
  read -rp "Overwrite the existing DNS record for $hostname_value? [y/N]: " overwrite
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
  c_err "Do not run setup with sudo. Run it as $SUDO_USER: ./backends/linux/setup.sh"
  c_err "Setup asks for sudo itself when it installs system software."
  exit 1
fi
# Missing system tools are installed with apt-get (Debian/Ubuntu) after one
# confirmation; other distributions get the list to install by hand.
NODE_MIN_MAJOR=18
NODE_INSTALL_MAJOR=24 # the Node.js line the Windows backend bundle ships
APT_APPROVED=0

confirm_system_install() {
  if [ "$(id -u)" -ne 0 ] && ! need sudo; then
    c_err "Missing: $*. Installing it needs root or sudo."
    exit 1
  fi
  [ "$APT_APPROVED" -eq 1 ] && return
  read -rp "Install missing system software ($*) with sudo? [Y/n]: " answer
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
  # A user-owned prefix (nvm) installs without sudo; a system one needs it.
  if [ -w "$(npm prefix -g)" ]; then
    npm install -g pm2
  else
    confirm_system_install pm2
    as_root npm install -g pm2
  fi
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

# Release packages ship build/web; RELAY_SERVE_WEB=0 keeps it unserved.
choose_web() {
  local answer
  if [ ! -f "$ROOT_DIR/build/web/index.html" ]; then
    c_warn "This copy has no Web client (build/web); the backend serves the API only."
    return
  fi
  read -rp "Serve the Web client at the backend address? [Y/n]: " answer
  case "${answer:-y}" in
    [Yy]*) set_env RELAY_SERVE_WEB 1 ;;
    *) set_env RELAY_SERVE_WEB 0 ;;
  esac
}

install_backend() {
install_prerequisites
install_server_deps
choose_web

PORT_NUM="$(grep -E '^PORT=' "$ENV_FILE" | cut -d= -f2 || true)"
PORT_NUM="${PORT_NUM:-8787}"

c_info "Relay setup"
cat <<EOF
Choose network mode:
  1) No tunnel / direct public address
  2) Cloudflare Tunnel / named stable hostname
  3) Cloudflare Quick Tunnel / temporary trycloudflare.com URL
EOF
read -rp "Network mode [1/2/3, default 3]: " NETWORK_MODE
NETWORK_MODE="${NETWORK_MODE:-3}"

case "$NETWORK_MODE" in
  1)
    # ---------- Direct mode (e.g. VPS with a public IP / domain) ----------
    c_info "Direct mode: the app connects straight to your address (no tunnel)."
    read -rp "Public address the app will use (e.g. https://agent.example.com or http://1.2.3.4:${PORT_NUM}): " PUBLIC_URL
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

    c_info "Generating credential QR..."
    credential --url "$PUBLIC_URL"
    ;;
  2)
    # ---------- Cloudflare named tunnel ----------
    ensure_cloudflared
    c_info "Cloudflare Tunnel mode: stable hostname through a named tunnel."
    read -rp "Public hostname for this backend (e.g. agent.example.com): " PUBLIC_HOSTNAME
    PUBLIC_HOSTNAME="$(url_hostname "$PUBLIC_HOSTNAME")"
    [ -n "$PUBLIC_HOSTNAME" ] || { c_err "A hostname is required for Cloudflare Tunnel mode."; exit 1; }
    DEFAULT_TUNNEL_NAME="$(default_tunnel_name)"
    read -rp "Cloudflare tunnel name [$DEFAULT_TUNNEL_NAME]: " TUNNEL_NAME
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

    c_info "Generating credential QR..."
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

    c_info "Generating credential QR..."
    credential
    ;;
  *)
    c_err "Invalid network mode: $NETWORK_MODE"
    exit 1
    ;;
esac

c_info "Done. In the app, tap \"Scan QR\", scan the QR above, and enter the password you just set."
c_info "Backend is managed by PM2 (pm2 list / pm2 logs / pm2 restart ${SERVER_PROC})."
c_info "Run ./backends/linux/setup.sh again for status, tokens, reinstall or uninstall."
}

# ---- menu ----
installed() { need pm2 && pm2_has "$SERVER_PROC"; }

read_token_id() {
  credential --list-tokens
  read -rp "Token id: " TOKEN_ID
  [ -n "$TOKEN_ID" ]
}

while true; do
  c_info "Relay backend"
  cat <<'MENU'
  1) Install
  2) Reinstall (keeps tokens, chats and settings)
  3) Uninstall all services
  4) Service status (address, agents, tokens)
  5) Create a new token
  6) Delete a token
  7) List tokens
  8) Show a token's credential QR again
  0) Exit
MENU
  read -rp "Choose [0-8]: " CHOICE || exit 0
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
      read -rp "Stop Relay, reinstall its dependencies and set up the network again? [y/N]: " answer
      case "$answer" in [Yy]*) ;; *) continue ;; esac
      if need pm2; then pm2 delete "$SERVER_PROC" "$TUNNEL_PROC" >/dev/null 2>&1 || true; fi
      rm -rf "$SERVER_DIR/node_modules"
      install_backend
      exit 0
      ;;
    3)
      read -rp "Stop and remove every Relay service, including the Web client? [y/N]: " answer
      case "$answer" in [Yy]*) exec "$LINUX_ADAPTER_DIR/uninstall.sh" ;; esac
      ;;
    4) "$LINUX_ADAPTER_DIR/status.sh" || true ;;
    5 | 6 | 7 | 8)
      if [ ! -f "$ENV_FILE" ] || [ ! -d "$SERVER_DIR/node_modules" ]; then
        c_warn "Relay is not installed here yet. Choose 1 first."
        continue
      fi
      case "$CHOICE" in
        5)
          read -rp "Label for the device that will use it [$(hostname)]: " LABEL
          credential --label "${LABEL:-$(hostname)}" || true
          ;;
        6)
          read_token_id || continue
          read -rp "Delete token $TOKEN_ID? Devices using it lose access. [y/N]: " answer
          case "$answer" in [Yy]*) credential --delete "$TOKEN_ID" || true ;; esac
          ;;
        7) credential --list-tokens ;;
        8) if read_token_id; then credential --show "$TOKEN_ID" || true; fi ;;
      esac
      ;;
    0) exit 0 ;;
    *) c_warn "Invalid choice: $CHOICE" ;;
  esac
done
