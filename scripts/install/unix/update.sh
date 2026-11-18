#!/usr/bin/env bash
# Update an installed Linux/macOS backend from a checksummed release archive.
set -euo pipefail

REPO="elin66alpha/Relay"

c_info() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
c_err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1; }

case "$(uname -s)" in
  Linux) platform=linux ;;
  Darwin) platform=macos ;;
  *)
    c_err "This updater is for Linux and macOS. On Windows, see https://github.com/$REPO/blob/main/docs/install.md"
    exit 1
    ;;
esac
if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
  c_err "Run the updater as $SUDO_USER without sudo."
  exit 1
fi
# macOS ships shasum instead of GNU sha256sum; both read the SHA256SUMS format.
if need sha256sum; then
  sha256_check() { sha256sum -c --status; }
elif need shasum; then
  sha256_check() { shasum -a 256 -c --status; }
else
  c_err "sha256sum or shasum is required. Install one, then rerun this command."
  exit 1
fi
for tool in curl tar; do
  need "$tool" || { c_err "$tool is required. Install it, then rerun this command."; exit 1; }
done
dir="${RELAY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)}"
if [ -e "$dir/.git" ] || [ ! -f "$dir/server/.env" ] || [ ! -f "$dir/server/server.js" ]; then
  c_err "Choose an installed release directory with server/.env and server/server.js."
  exit 1
fi

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

# Existing installations are upgraded without running setup again. Check the
# new runtime requirement before removing or replacing any of their files.
if [ "$(printf '%s\n' 0.1.10 "$version" | sort -V | head -n 1)" = 0.1.10 ]; then
  current_node="$(node -p "Number(process.versions.node.split('.')[0])" 2>/dev/null || echo 0)"
  if [ "$current_node" -lt 22 ] || ! need npm; then
    c_err "Relay $version needs Node.js 22+ and npm. Upgrade them before rerunning the installer; the existing installation was not changed."
    exit 1
  fi
fi

name="relay-backend-linux-macos-v$version.tar.gz"
if [[ "$version" =~ ^0\.1\.([0-9]+)$ ]] && (( BASH_REMATCH[1] <= 12 )); then
  name="relay-backend-setup-v$version.tar.gz"
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
c_info "Downloading Relay $version..."
base="https://github.com/$REPO/releases/download/v$version"
curl -fL --progress-bar "$base/$name" -o "$tmp/$name"
curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"
(cd "$tmp" && grep " $name\$" SHA256SUMS | sha256_check) || {
  c_err "The download does not match the release checksum. Nothing was installed."
  exit 1
}

# Parse this function before extraction replaces the running script.
apply_update() {
  # The Web client's files change names between builds; replace it whole.
  rm -rf "$dir/app/shell/build/web"
  # Releases before 0.1.10 kept the Web client in build/web and these scripts in
  # backends/.
  rm -rf "$dir/build/web" "$dir/backends"
  # Releases before 0.1.12 kept separate Linux and macOS helpers, now in unix/lib.
  rm -rf "$dir/scripts/install/linux/lib" "$dir/scripts/install/macos/lib"
  tar -xzf "$tmp/$name" -C "$dir" --strip-components=1
  c_info "Relay $version unpacked in $dir"

  c_info "Upgrading: installing server dependencies..."
  (cd "$dir/server" && npm install)
  if [ "$platform" = linux ]; then
    if need pm2 && pm2 describe relay-server >/dev/null 2>&1; then
      # --update-env also refreshes PATH, so newly installed agent CLIs are found.
      pm2 restart relay-server --update-env
      pm2 save >/dev/null 2>&1 || true
    fi
  else
    # The label setup gives the backend LaunchAgent (unix/lib/macos.sh).
    agent="gui/$(id -u)/dev.relay.app.backend"
    if launchctl print "$agent" >/dev/null 2>&1; then
      launchctl kickstart -k "$agent"
    fi
  fi
  c_info "Upgraded to $version. Tokens, chats and settings are unchanged."
  c_info "For status, tokens or agent CLIs run: $dir/scripts/install/$platform/setup.sh"
}
apply_update
