#!/usr/bin/env bash
# macOS adapter for lib/common.sh: Homebrew installs system software and two
# per-user LaunchAgents run the services. LaunchAgents start at login and are
# restarted by launchd, which PM2 would need `sudo pm2 startup` to match.

PLATFORM_LABEL="macOS"
SERVER_LABEL="dev.relay.app.backend"
TUNNEL_LABEL="dev.relay.app.tunnel"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/Relay"
SERVER_PLIST="$LAUNCH_AGENTS_DIR/$SERVER_LABEL.plist"
TUNNEL_PLIST="$LAUNCH_AGENTS_DIR/$TUNNEL_LABEL.plist"

# launchd starts services with a minimal PATH; agent CLIs live in these.
RELAY_PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.opencode/bin:$HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Homebrew's prefix is missing from PATH in shells that skipped its shellenv.
for brew_bin in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$brew_bin:"*) ;; *) [ ! -d "$brew_bin" ] || PATH="$PATH:$brew_bin" ;; esac
done

system_install() {
  need brew || {
    c_err "Missing: $*. Install Homebrew (https://brew.sh) and rerun setup, or install them yourself."
    exit 1
  }
  confirm_system_install Homebrew "$@"
  c_info "Installing $*..."
  brew install "$@"
  hash -r
}

install_prerequisites() {
  if ! need node || [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
    if need node; then
      c_warn "Node.js $(node -v) is older than $NODE_MIN_MAJOR; installing the current Node.js."
    fi
    system_install node
    if [ "$(node_major)" -lt "$NODE_MIN_MAJOR" ]; then
      c_err "Node.js >= $NODE_MIN_MAJOR is still not first on PATH ($(command -v node || echo 'node not found'))."
      c_err "Remove or update that older Node.js, then rerun setup."
      exit 1
    fi
  fi
  need npm || { c_err "npm is missing from this Node.js installation. Reinstall Node.js, then rerun setup."; exit 1; }
  need zip || system_install zip
}

# node-pty ships prebuilt darwin-x64 and darwin-arm64 binaries, so before npm
# has installed it nothing is needed; the Xcode Command Line Tools matter only
# when that binary does not load and it has to compile.
ensure_pty_build_tools() {
  [ -d "$SERVER_DIR/node_modules/node-pty" ] || return 0
  xcode-select -p >/dev/null 2>&1 && return
  c_warn "The terminal's PTY module needs the Xcode Command Line Tools."
  xcode-select --install >/dev/null 2>&1 || true
  c_err "Finish the Command Line Tools install in the window that opened, then rerun setup."
  exit 1
}

ensure_cloudflared() {
  need cloudflared || system_install cloudflared
  need cloudflared || { c_err "cloudflared is required for Cloudflare tunnel modes."; exit 1; }
}

launch_domain() { printf 'gui/%s' "$(id -u)"; }
agent_label() { if [ "$1" = tunnel ]; then printf '%s' "$TUNNEL_LABEL"; else printf '%s' "$SERVER_LABEL"; fi; }

svc_registered() { launchctl print "$(launch_domain)/$(agent_label "$1")" >/dev/null 2>&1; }

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "$value"
}

# write_plist <label> <plist> <log name> <working dir> <program> [args...]
write_plist() {
  local label="$1" plist="$2" log="$3" workdir="$4" arg
  shift 4
  mkdir -p "$LAUNCH_AGENTS_DIR" "$LOG_DIR"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
EOF
    for arg in "$@"; do printf '    <string>%s</string>\n' "$(xml_escape "$arg")"; done
    cat <<EOF
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$workdir")</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$(xml_escape "$RELAY_PATH")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LOG_DIR/$log.out.log")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LOG_DIR/$log.err.log")</string>
</dict>
</plist>
EOF
  } >"$plist"
}

start_agent() {
  local label="$1" plist="$2" domain
  domain="$(launch_domain)"
  launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  # bootout can return before launchd has let go of the label ("Bootstrap
  # failed: 5"); update.sh restarts through here, so retry once.
  launchctl bootstrap "$domain" "$plist" 2>/dev/null || { sleep 2; launchctl bootstrap "$domain" "$plist"; }
  launchctl enable "$domain/$label" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$label"
}

stop_agent() { launchctl bootout "$(launch_domain)/$1" >/dev/null 2>&1 || true; }

# The backend alone; the tunnel keeps running, so a Quick Tunnel keeps its URL.
svc_restart_server() {
  local node
  node="$(command -v node)" || { c_err "Node.js is not on PATH."; exit 1; }
  # The Node running setup goes first: nvm, fnm and Volta keep it, and the CLIs
  # npm installs beside it, outside the fixed directories. (local: write_plist
  # reads it.)
  local RELAY_PATH="${node%/*}:$RELAY_PATH"
  write_plist "$SERVER_LABEL" "$SERVER_PLIST" backend "$SERVER_DIR" "$node" "$SERVER_DIR/server.js"
  start_agent "$SERVER_LABEL" "$SERVER_PLIST"
}

# Both LaunchAgents are rewritten from server/.env, as PM2 reads it on Linux.
svc_start() {
  local bin args=()
  svc_restart_server
  if [ "$(tunnel_mode)" = cloudflare ] && [ -z "$(get_env CLOUDFLARED_ARGS)" ] && [ -f "$TUNNEL_PLIST" ]; then
    # Named tunnels set up before 0.1.12 kept their arguments only in the plist.
    start_agent "$TUNNEL_LABEL" "$TUNNEL_PLIST"
  elif tunnel_enabled; then
    bin="$(get_env CLOUDFLARED_BIN)"
    # Word splitting is intended: CLOUDFLARED_ARGS is one argument string.
    set -f
    # shellcheck disable=SC2207
    args=($(tunnel_args))
    set +f
    write_plist "$TUNNEL_LABEL" "$TUNNEL_PLIST" tunnel "$SERVER_DIR" "${bin:-cloudflared}" "${args[@]}"
    start_agent "$TUNNEL_LABEL" "$TUNNEL_PLIST"
  else
    stop_agent "$TUNNEL_LABEL"
    rm -f "$TUNNEL_PLIST"
  fi
}

# Booted-out agents stay installed: launchd starts them again at next login.
svc_stop() {
  c_info "Stopping $TUNNEL_LABEL"
  stop_agent "$TUNNEL_LABEL"
  c_info "Stopping $SERVER_LABEL"
  stop_agent "$SERVER_LABEL"
}

svc_remove() {
  local label
  for label in "$TUNNEL_LABEL" "$SERVER_LABEL"; do
    stop_agent "$label"
    if [ -f "$LAUNCH_AGENTS_DIR/$label.plist" ]; then
      rm -f "$LAUNCH_AGENTS_DIR/$label.plist"
      printf '  removed %s\n' "$label"
    fi
  done
}

browser_install_hint() {
  printf '%s' 'Install one, for example: brew install --cask google-chrome'
}

svc_summary() {
  local label line
  for label in "$SERVER_LABEL" "$TUNNEL_LABEL"; do
    if line="$(launchctl print "$(launch_domain)/$label" 2>/dev/null)"; then
      printf '  %-24s %s\n' "$label" "$(printf '%s\n' "$line" | awk -F' = ' '/^\tstate = /{s=$2} /^\tpid = /{p=" (pid " $2 ")"} END{print s p}')"
    else
      printf '  %-24s not loaded\n' "$label"
    fi
  done
}

server_log_files() { printf '%s\n' "$LOG_DIR/backend.out.log" "$LOG_DIR/backend.err.log"; }
tunnel_log_files() { printf '%s\n' "$LOG_DIR/tunnel.err.log" "$LOG_DIR/tunnel.out.log"; }

service_hint() {
  printf 'Backend runs as the LaunchAgent %s; logs are in %s (tail -f %s/backend.err.log).\n' \
    "$SERVER_LABEL" "$LOG_DIR" "$LOG_DIR"
  printf 'It starts when you log in to this Mac, so after a restart Relay waits for a login.\n'
}

# The installation the registered backend runs from, or nothing.
svc_root() {
  [ -f "$SERVER_PLIST" ] || return 0
  sed -n '/<key>WorkingDirectory<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$SERVER_PLIST" |
    sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g; s,/server$,,'
}

brew_has() { need brew && brew list --formula "$1" >/dev/null 2>&1; }

remove_system_software() {
  if need cloudflared && ask_no "Remove cloudflared?"; then
    if brew_has cloudflared; then
      brew uninstall cloudflared
    else
      c_warn "cloudflared at $(command -v cloudflared) was not installed by Homebrew; remove it by hand."
    fi
  fi
  if need node && ask_no "Remove Node.js? Other programs on this Mac may need it."; then
    if brew_has node; then
      brew uninstall node
    else
      c_warn "Node.js at $(command -v node) was not installed by Homebrew; remove it the same way you installed it."
    fi
  fi
}
