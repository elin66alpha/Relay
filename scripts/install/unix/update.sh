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
current="$(grep -m 1 -E '^[[:space:]]*"version"' "$dir/server/package.json" 2>/dev/null |
  sed -E 's/.*"version":[[:space:]]*"([^"]+)".*/\1/' || true)"
# Reinstalling the same version would only interrupt running turns. An
# explicit RELAY_VERSION still installs, even an older one.
if [ -z "${RELAY_VERSION:-}" ] && [ -n "$current" ] &&
   [ "$(printf '%s\n' "$version" "$current" | sort -V | tail -n 1)" = "$current" ]; then
  c_info "Relay $current is already the latest version."
  exit 0
fi

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

# These trees hold release files only, so they are swapped whole, which also
# drops files a release no longer ships. Every other release file sits beside
# state (server/.env, tokens.json, chats) and is replaced one by one.
TREES="server/lib server/routes server/scripts server/node_modules scripts/install app/shell/build/web"
new="$dir/.relay-update-new"
# The previous version, until the new one answers. Its presence marks an
# update that has not finished.
old="$dir/.relay-update-old"

# Moves the previous version aside and the staged one in, recording in $old
# what it moved so restore_old can undo every step, even after an interruption.
swap_in() {
  local rel
  mkdir -p "$old" || return 1
  : >>"$old/.added"
  for rel in $TREES; do
    if [ -e "$dir/$rel" ]; then
      mkdir -p "$(dirname "$old/$rel")" && mv "$dir/$rel" "$old/$rel" || return 1
    else
      printf '%s\n' "$rel" >>"$old/.added"
    fi
    if [ -e "$new/$rel" ]; then
      mkdir -p "$(dirname "$dir/$rel")" && mv "$new/$rel" "$dir/$rel" || return 1
    fi
  done
  (cd "$new" && find . -type f) | while IFS= read -r rel; do
    rel="${rel#./}"
    if [ -e "$dir/$rel" ]; then
      mkdir -p "$(dirname "$old/$rel")" && mv "$dir/$rel" "$old/$rel" || exit 1
    else
      printf '%s\n' "$rel" >>"$old/.added"
    fi
    mkdir -p "$(dirname "$dir/$rel")" && cp -p "$new/$rel" "$dir/$rel" || exit 1
  done
}

# Puts the version in $old back. On failure $old stays for the next run.
restore_old() {
  local rel
  for rel in $TREES; do
    if [ -e "$old/$rel" ]; then
      rm -rf "${dir:?}/$rel" && mv "$old/$rel" "$dir/$rel" || return 1
    fi
  done
  if [ -f "$old/.added" ]; then
    while IFS= read -r rel; do rm -rf "${dir:?}/$rel" || return 1; done <"$old/.added"
    rm -f "$old/.added"
  fi
  (cd "$old" && find . -type f) | while IFS= read -r rel; do
    rel="${rel#./}"
    mkdir -p "$(dirname "$dir/$rel")" && mv -f "$old/$rel" "$dir/$rel" || exit 1
  done || return 1
  rm -rf "$old"
}

rm -rf "$new" "$dir/.relay-update-done"
if [ -d "$old" ]; then
  c_info "Restoring the version an interrupted update left in $old..."
  restore_old || { c_err "Could not restore $old. Move its files back into $dir by hand, then rerun this command."; exit 1; }
fi

# Staged and installed beside the running version, so a failed download,
# dependency install or build leaves the installation as it was.
mkdir -p "$new"
tar -xzf "$tmp/$name" -C "$new" --strip-components=1
[ -f "$new/server/server.js" ] || { rm -rf "$new"; c_err "The archive is not a Relay backend. Nothing was changed."; exit 1; }
c_info "Installing the server dependencies of Relay $version..."
(cd "$new/server" && npm ci --omit=dev) || {
  rm -rf "$new"
  c_err "Installing the dependencies of Relay $version failed. Nothing was changed."
  exit 1
}

if ! swap_in; then
  c_err "Replacing the files failed; putting Relay ${current:-the previous version} back."
  restore_old || c_err "Could not restore $old. Move its files back into $dir by hand."
  rm -rf "$new"
  exit 1
fi
rm -rf "$new"
c_info "Relay $version unpacked in $dir"

# The new release's own adapter restarts the backend, so a changed LaunchAgent
# or PM2 definition reaches upgraded installations too.
# shellcheck source=lib/common.sh
source "$dir/scripts/install/unix/lib/common.sh"
# The sourced scripts share this shell's variables; ROOT_DIR is this same
# installation, resolved.
dir="$ROOT_DIR"
restart_backend() {
  # Releases before this one have no svc_restart_server.
  if declare -F svc_restart_server >/dev/null; then svc_restart_server; else svc_start; fi
}

# Any HTTP answer on the backend port means the new version is serving.
backend_answers() {
  local host
  host="$(get_env HOST)"
  case "$host" in "" | 0.0.0.0) host=127.0.0.1 ;; esac
  for _ in $(seq 1 30); do
    sleep 1
    ! curl -s -o /dev/null --max-time 2 "http://$host:$(backend_port)/" || return 0
  done
  return 1
}

if ! svc_registered server; then
  mv "$old" "$dir/.relay-update-done" && rm -rf "$dir/.relay-update-done"
  c_info "Upgraded to $version. Relay is not running here; start it with $(script_path start.sh)."
  exit 0
fi
c_info "Restarting the backend..."
if restart_backend && backend_answers; then
  mv "$old" "$dir/.relay-update-done" && rm -rf "$dir/.relay-update-done"
  # Releases before 0.1.10 kept the Web client in build/web and these scripts in backends/.
  rm -rf "$dir/build/web" "$dir/backends"
  c_info "Upgraded to $version. Tokens, chats and settings are unchanged."
  c_info "For status, tokens or agent CLIs run: $dir/scripts/install/$platform/setup.sh"
  exit 0
fi

c_err "Relay $version did not start within 30 seconds; putting Relay ${current:-the previous version} back."
c_err "Its logs: $(server_log_files | tr '\n' ' ')"
restore_old || { c_err "Could not restore $old. Move its files back into $dir by hand."; exit 1; }
restart_backend || true
if backend_answers; then
  c_info "Relay ${current:-the previous version} is running again."
else
  c_err "The previous version did not start either; see the logs above."
fi
exit 1
