#!/usr/bin/env bash
#
# One-line Relay backend install for Linux:
#
#   curl -fsSL https://github.com/elin66alpha/Relay/releases/latest/download/install.sh | bash
#
# Downloads the latest release's backend setup bundle, checks it against the
# release's SHA256SUMS and unpacks it into ~/relay (or the directory chosen at
# the prompt or in RELAY_DIR). A fresh copy then runs setup; running the command
# again upgrades the code in place, keeps server/.env, tokens, chats and
# settings, and restarts the backend. RELAY_VERSION=0.1.9 pins a release.
#
set -euo pipefail

REPO="elin66alpha/Relay"

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

[ "$(uname -s)" = Linux ] || {
  c_err "This installer is for Linux. On macOS and Windows, see https://github.com/$REPO/blob/main/docs/install.md"
  exit 1
}
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  c_err "Do not run the installer with sudo; run it as $SUDO_USER. Setup asks for sudo itself when needed."
  exit 1
fi
for tool in curl tar sha256sum; do
  need "$tool" || { c_err "$tool is required. Install it, then rerun this command."; exit 1; }
done
# Piped into bash, stdin is the script itself; questions go to the terminal.
[ -r /dev/tty ] || { c_err "Run this from an interactive terminal."; exit 1; }

version="${RELAY_VERSION:-}"
if [ -z "$version" ]; then
  # .../releases/latest redirects to .../releases/tag/v<VERSION>.
  latest="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")"
  version="${latest##*/v}"
fi
case "$version" in
  [0-9]*) ;;
  *) c_err "Could not find the latest Relay release."; exit 1 ;;
esac

dir="${RELAY_DIR:-}"
if [ -z "$dir" ]; then
  printf '\n\033[1;36m▶\033[0m Install directory [~/relay]: ' >/dev/tty
  read -r dir </dev/tty
fi
dir="${dir:-$HOME/relay}"
case "$dir" in "~"*) dir="$HOME${dir#\~}" ;; esac
if [ -e "$dir" ] && [ ! -f "$dir/server/server.js" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
  c_err "$dir is not empty and is not a Relay install. Choose another directory."
  exit 1
fi
upgrade=0
[ -f "$dir/server/.env" ] && upgrade=1

# Existing installations are upgraded without running setup again. Check the
# new runtime requirement before removing or replacing any of their files.
if [ "$upgrade" -eq 1 ] && [ "$(printf '%s\n' 0.1.10 "$version" | sort -V | head -n 1)" = 0.1.10 ]; then
  current_node="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
  if [ "$current_node" -lt 22 ] || ! need npm; then
    c_err "Relay $version needs Node.js 22+ and npm. Upgrade them before rerunning the installer; the existing installation was not changed."
    exit 1
  fi
fi

name="relay-backend-setup-v$version.tar.gz"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
c_info "Downloading Relay $version..."
base="https://github.com/$REPO/releases/download/v$version"
curl -fL --progress-bar "$base/$name" -o "$tmp/$name"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep " $name\$" SHA256SUMS | sha256sum -c --status) || {
  c_err "The download does not match the release checksum. Nothing was installed."
  exit 1
}

mkdir -p "$dir"
# The Web client's files change names between builds; replace it whole.
rm -rf "$dir/app/shell/build/web"
# Releases before 0.1.10 kept the Web client in build/web and these scripts in
# backends/.
rm -rf "$dir/build/web" "$dir/backends"
tar -xzf "$tmp/$name" -C "$dir" --strip-components=1
c_info "Relay $version unpacked in $dir"

if [ "$upgrade" -eq 1 ]; then
  c_info "Upgrading: installing server dependencies..."
  (cd "$dir/server" && npm install)
  if need pm2 && pm2 describe relay-server >/dev/null 2>&1; then
    # --update-env also refreshes PATH, so newly installed agent CLIs are found.
    pm2 restart relay-server --update-env
    pm2 save >/dev/null 2>&1 || true
  fi
  c_info "Upgraded to $version. Tokens, chats and settings are unchanged."
  c_info "For status, tokens or agent CLIs run: $dir/scripts/install/linux/setup.sh"
  exit 0
fi

exec "$dir/scripts/install/linux/setup.sh" install </dev/tty
