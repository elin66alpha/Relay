#!/usr/bin/env bash
# Shared by every Unix backend script. Linux and macOS run the same menu,
# questions and steps; only installing system software and running the two
# services differ, and those live in lib/linux.sh (apt-get, PM2) and
# lib/macos.sh (Homebrew, launchd). Each adapter defines:
#
#   PLATFORM, PLATFORM_LABEL     linux|macos, and the name shown to the user
#   system_install <pkg>...      install system packages after one confirmation
#   install_prerequisites        Node.js 22+, npm, zip and the service manager
#   ensure_pty_build_tools       what node-pty needs when it has to compile
#   ensure_cloudflared           cloudflared, for both tunnel modes
#   svc_start [fresh]            start the backend, plus the tunnel when
#                                server/.env enables one; fresh re-registers
#   svc_stop                     stop both, keeping their registration
#   svc_remove                   stop and unregister both
#   svc_registered server|tunnel whether the service is registered
#   svc_summary                  the service manager's own view, for status
#   server_log_files, tunnel_log_files   one path per line
#   service_hint                 how to manage the services directly
#   remove_system_software       uninstall's offer to remove what setup added
#
# Bash 3.2 compatible: macOS ships no newer bash.

UNIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT_DIR="$(cd "$UNIX_DIR/../../.." && pwd -P)"
SERVER_DIR="$ROOT_DIR/server"
ENV_FILE="$SERVER_DIR/.env"
ENV_EXAMPLE="$SERVER_DIR/.env.example"
TUNNEL_CONFIG_DIR="$SERVER_DIR/cloudflared-config"
WEB_DIR="$ROOT_DIR/app/shell/build/web"
# The isolated file access choice confines agents here, as on Windows.
WORKSPACE_DIR="$ROOT_DIR/workspace"
NODE_MIN_MAJOR=22

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_err()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }
# Every place setup waits for an answer opens with a banner, and each question
# starts with ASK, so the choices stand out from installer output.
section() {
  local rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '\n\033[1;36m%s\n  %s\n%s\033[0m\n' "$rule" "$*" "$rule"
}
ASK=$'\n\033[1;36m▶\033[0m '

need() { command -v "$1" >/dev/null 2>&1; }
as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

ask_no() {
  local answer
  read -rp "${ASK}$1 [y/N]: " answer
  case "$answer" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Under sudo, the services, their state files and agent CLI logins would all
# belong to root instead of the user who runs Relay.
refuse_sudo() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    c_err "Do not run this with sudo. Run it as $SUDO_USER: $(script_path "$1")"
    c_err "Setup asks for sudo itself when it installs system software."
    exit 1
  fi
}

# The path users run, under scripts/install/<platform>/.
script_path() { printf './scripts/install/%s/%s' "$PLATFORM" "$1"; }

# One confirmation covers every system install in a run.
SYSTEM_INSTALL_APPROVED=0
confirm_system_install() {
  local how="$1" answer
  shift
  [ "$SYSTEM_INSTALL_APPROVED" -eq 1 ] && return
  read -rp "${ASK}Install missing system software ($*) with $how? [Y/n]: " answer
  case "${answer:-y}" in
    [Yy]*) SYSTEM_INSTALL_APPROVED=1 ;;
    *) c_err "Missing: $*. Install it, then rerun setup."; exit 1 ;;
  esac
}

require_sudo() {
  if [ "$(id -u)" -ne 0 ] && ! need sudo; then
    c_err "Missing: $*. Installing it needs root or sudo."
    exit 1
  fi
}

# A user-owned prefix (nvm, Homebrew) installs without sudo; a system one needs it.
npm_install_global() {
  if [ -w "$(npm prefix -g)" ]; then
    npm install -g "$@"
  else
    require_sudo "$@"
    confirm_system_install "sudo npm" "$@"
    as_root npm install -g "$@"
  fi
}

node_major() { node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0; }

credential() { (cd "$SERVER_DIR" && node scripts/create-credential.js "$@"); }

ensure_env_file() {
  if [ ! -f "$ENV_FILE" ]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    c_info "Created server/.env from .env.example"
  fi
}

get_env() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true
}

# Upsert KEY=VALUE into server/.env (pure bash; safe for URLs with / and :).
set_env() {
  local key="$1" val="$2" tmp line
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

backend_port() {
  local port
  port="$(get_env PORT)"
  printf '%s' "${port:-8787}"
}

# Matches ecosystem.config.js: anything other than "none" also runs a tunnel.
tunnel_mode() {
  local mode
  mode="$(get_env RELAY_TUNNEL_MODE)"
  printf '%s' "${mode:-quick}"
}

tunnel_enabled() { [ "$(tunnel_mode)" != "none" ]; }

# The arguments cloudflared runs with, as setup wrote them to server/.env.
tunnel_args() {
  local args
  args="$(get_env CLOUDFLARED_ARGS)"
  printf '%s' "${args:-tunnel --url http://127.0.0.1:$(backend_port)}"
}

# CLOUDFLARED_ARGS is "tunnel --config <file> run <id>" for a named tunnel.
named_tunnel_config() {
  get_env CLOUDFLARED_ARGS | sed -nE 's/.*--config ([^ ]+).*/\1/p'
}

# Matches server.js: app/shell/build/web is served unless RELAY_SERVE_WEB=0.
web_state() {
  if [ ! -f "$WEB_DIR/index.html" ]; then
    printf 'not installed'
  elif [ "$(get_env RELAY_SERVE_WEB)" = "0" ]; then
    printf 'installed, disabled (RELAY_SERVE_WEB=0)'
  else
    printf 'served at /'
  fi
}

file_access_state() {
  local root
  root="$(get_env RELAY_WORKSPACE_ROOT)"
  if [ -n "$root" ]; then printf 'isolated to %s' "$root"; else printf 'open'; fi
}

require_setup() {
  [ -f "$ENV_FILE" ] && [ -d "$SERVER_DIR/node_modules" ] || {
    c_err "Relay is not set up here yet. Run $(script_path setup.sh) first."
    exit 1
  }
}

latest_quick_url() {
  local files=() file
  while IFS= read -r file; do files+=("$file"); done < <(tunnel_log_files)
  grep -hoE 'https://[a-z0-9-]+\.trycloudflare\.com' "${files[@]}" 2>/dev/null | tail -1 || true
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

case "$(uname -s)" in
  Linux) PLATFORM=linux ;;
  Darwin) PLATFORM=macos ;;
  *) c_err "These scripts run on Linux and macOS. On Windows use scripts/install/windows."; exit 1 ;;
esac
# shellcheck source=/dev/null
source "$UNIX_DIR/lib/$PLATFORM.sh"
