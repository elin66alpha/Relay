#!/usr/bin/env bash
#
# Reusable Ubuntu 24.04 Docker sandbox for testing Relay Linux backend bundles
# and in-place upgrades without colliding with the host backend.
#
#   ./scripts/dev/backend-sandbox/sandbox.sh <build|install <tarball>|update [version]|shell|status|destroy>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
IMAGE_NAME="${RELAY_SANDBOX_IMAGE:-relay-sandbox:latest}"
CONTAINER_NAME="${RELAY_SANDBOX_CONTAINER:-relay-sandbox}"
VOLUME_NAME="${RELAY_SANDBOX_VOLUME:-relay-sandbox-home}"
PORT="${RELAY_SANDBOX_PORT:-18787}"
INSTALL_DIR="/home/relay/relay"
PASSPHRASE="${RELAY_CREDENTIAL_PASSPHRASE:-sandbox-pass}"

usage() {
  cat <<'EOF'
Usage: sandbox.sh <command>

Commands:
  build               Build the Ubuntu 24.04 sandbox image
  install <tarball>   Extract a release tarball and run ./install.sh inside the sandbox
  update [version]    Run the installed update.sh inside the sandbox (optional RELAY_VERSION)
  shell               Open an interactive bash shell as relay inside the sandbox
  status              Show pm2 list and the host-loopback health HTTP status code
  destroy             Remove the sandbox container and its home volume
EOF
}

ensure_image() {
  if ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
    cmd_build
  fi
}

ensure_pm2_ready() {
  # Wait for the container's boot-time pm2 resurrect/ping to finish starting the
  # God Daemon and bind rpc.sock so concurrent `pm2` calls never spawn a second daemon.
  docker exec "$CONTAINER_NAME" bash -c '
    for _ in $(seq 1 40); do
      if [ -S "$HOME/.pm2/rpc.sock" ] && pgrep -f "PM2.*God Daemon" >/dev/null 2>&1; then
        exit 0
      fi
      sleep 0.25
    done
    exit 1
  ' >/dev/null
}

ensure_container() {
  local running
  running="$(docker container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  case "$running" in
    true)
      ensure_pm2_ready
      return 0
      ;;
    false)
      docker start "$CONTAINER_NAME" >/dev/null
      ensure_pm2_ready
      ;;
    *)
      ensure_image
      docker volume create "$VOLUME_NAME" >/dev/null
      docker run -d \
        --name "$CONTAINER_NAME" \
        -v "$VOLUME_NAME:/home/relay" \
        -p "127.0.0.1:${PORT}:${PORT}" \
        "$IMAGE_NAME" >/dev/null
      ensure_pm2_ready
      ;;
  esac
}

cmd_build() {
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
}

cmd_install() {
  if [ $# -ne 1 ] || [ ! -f "$1" ]; then
    echo "Usage: $0 install <tarball>" >&2
    exit 1
  fi
  local tarball="$1"
  ensure_container

  docker exec -i "$CONTAINER_NAME" sh -c 'cat > /tmp/relay-bundle.tar.gz' < "$tarball"

  docker exec -i \
    -e "SANDBOX_PORT=$PORT" \
    -e "INSTALL_DIR=$INSTALL_DIR" \
    -e "RELAY_CREDENTIAL_PASSPHRASE=$PASSPHRASE" \
    "$CONTAINER_NAME" bash -s <<'EOF'
set -euo pipefail
pm2 delete relay-server relay-tunnel >/dev/null 2>&1 || true
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
tar -xzf /tmp/relay-bundle.tar.gz -C "$INSTALL_DIR" --strip-components=1
rm -f /tmp/relay-bundle.tar.gz

cd "$INSTALL_DIR"
# Pre-seed server/.env with PORT so setup.sh configures mode 1 and device
# credentials for the container's published port instead of 8787.
cp server/.env.example server/.env
sed -i -E "s/^PORT=.*/PORT=${SANDBOX_PORT}/" server/.env

# setup.sh prompts via `read -rp` with no non-interactive env-var bypass:
#   Step 2 (Agent CLIs): empty line = skip installing CLIs
#   Step 3 (Web client, asked only when app/shell/build/web/index.html exists): n = disable Web
#   Step 4 (File access): 1 = Open
#   Step 5 (Network mode): 1 = No tunnel / direct, then http://127.0.0.1:<PORT>
# Step 6 uses RELAY_CREDENTIAL_PASSPHRASE from the environment without prompting.
answers='\n'
if [ -f app/shell/build/web/index.html ]; then
  answers="${answers}n\n"
fi
answers="${answers}1\n1\nhttp://127.0.0.1:${SANDBOX_PORT}\n"
printf '%b' "$answers" | ./install.sh

# Wait briefly for PM2's relay-server to bind the port before `status` runs.
node -e '
const net = require("node:net");
const port = Number(process.env.SANDBOX_PORT);
const deadline = Date.now() + 15000;
function probe() {
  const s = net.connect(port, "127.0.0.1");
  s.once("connect", () => { s.destroy(); process.exit(0); });
  s.once("error", () => {
    s.destroy();
    if (Date.now() >= deadline) process.exit(1);
    setTimeout(probe, 250);
  });
}
probe();
'
EOF
}

cmd_update() {
  if [ $# -gt 1 ]; then
    echo "Usage: $0 update [version]" >&2
    exit 1
  fi
  local version="${1:-}"
  ensure_container

  local env_args=(-e "RELAY_DIR=$INSTALL_DIR")
  if [ -n "$version" ]; then
    env_args+=(-e "RELAY_VERSION=$version")
  fi
  docker exec "${env_args[@]}" "$CONTAINER_NAME" bash -c '
    set -euo pipefail
    if [ ! -f "$RELAY_DIR/scripts/install/unix/update.sh" ]; then
      echo "Relay is not installed in $RELAY_DIR." >&2
      exit 1
    fi
    exec bash "$RELAY_DIR/scripts/install/unix/update.sh"
  '
}

cmd_shell() {
  ensure_container
  if [ -t 0 ] && [ -t 1 ]; then
    exec docker exec -it "$CONTAINER_NAME" bash -l
  else
    exec docker exec -i "$CONTAINER_NAME" bash -l
  fi
}

cmd_status() {
  local running code
  running="$(docker container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  if [ "$running" != "true" ]; then
    echo "Container $CONTAINER_NAME is not running (state: ${running:-missing})." >&2
    exit 1
  fi
  ensure_pm2_ready
  docker exec "$CONTAINER_NAME" pm2 list
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT}/api/health" || true)"
  printf 'Health (http://127.0.0.1:%s/api/health): HTTP %s\n' "$PORT" "${code:-000}"
  case "${code:-000}" in
    200|401|503) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_destroy() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  docker volume rm "$VOLUME_NAME" >/dev/null 2>&1 || true
  echo "Removed $CONTAINER_NAME and volume $VOLUME_NAME."
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  install) shift; cmd_install "$@" ;;
  update) shift; cmd_update "$@" ;;
  shell) shift; cmd_shell "$@" ;;
  status) shift; cmd_status "$@" ;;
  destroy) shift; cmd_destroy "$@" ;;
  *)
    usage >&2
    exit 1
    ;;
esac
