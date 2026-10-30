#!/usr/bin/env bash
# Package a Flutter Linux release bundle for Ubuntu x86-64.
# Build the bundle and run this on Ubuntu 22.04 for distributable releases.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle="${1:-$root/app/shell/build/linux/x64/release/bundle}"
output="${2:-$root/build/release}"
version="$(node -p "require(process.argv[1]).version" "$root/server/package.json")"
package="relay-desktop_${version}_amd64.deb"

[ "$(dpkg --print-architecture)" = amd64 ] || { echo 'An amd64 Ubuntu build host is required.' >&2; exit 1; }
[ -x "$bundle/relay" ] && [ -f "$bundle/lib/libflutter_linux_gtk.so" ] || {
  echo 'Build the Flutter Linux release bundle first.' >&2; exit 1;
}
[ ! -e "$output/$package" ] || { echo "Package already exists: $output/$package" >&2; exit 1; }
desktop-file-validate "$root/app/shell/linux/dev.relay.app.desktop"

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
package_root="$stage/debian/relay-desktop"
app="$package_root/usr/lib/relay-desktop"
mkdir -p "$package_root/DEBIAN" "$app" "$package_root/usr/bin"
cp -a "$bundle/." "$app/"
ln -s ../lib/relay-desktop/relay "$package_root/usr/bin/relay-desktop"
install -Dm644 "$root/app/shell/linux/dev.relay.app.desktop" \
  "$package_root/usr/share/applications/dev.relay.app.desktop"
for size in 16 32 64 128 256 512; do
  install -Dm644 "$root/app/shell/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_${size}.png" \
    "$package_root/usr/share/icons/hicolor/${size}x${size}/apps/dev.relay.app.png"
done
install -Dm644 "$root/LICENSE" "$package_root/usr/share/doc/relay-desktop/copyright"

cat > "$stage/debian/control" <<'EOF'
Source: relay-desktop
Section: utils
Priority: optional
Maintainer: Relay Contributors <noreply@github.com>
Standards-Version: 4.6.0

Package: relay-desktop
Architecture: amd64
Description: Relay desktop client
EOF
depends="$(cd "$stage" && dpkg-shlibdeps -O -xrelay-desktop -l"$app/lib" \
  "$app/relay" "$app/lib/libflutter_linux_gtk.so" \
  "$app/lib/libflutter_secure_storage_linux_plugin.so")"
depends="${depends#shlibs:Depends=}"
installed_size="$(du -sk "$package_root" | cut -f1)"
cat > "$package_root/DEBIAN/control" <<EOF
Package: relay-desktop
Version: $version
Architecture: amd64
Installed-Size: $installed_size
Maintainer: Relay Contributors <noreply@github.com>
Section: utils
Priority: optional
Depends: $depends
Recommends: gnome-keyring, xdg-desktop-portal
Homepage: https://github.com/elin66alpha/Relay
Description: Private desktop client for coding agents
 Connect to a self-hosted Relay backend to control coding agents.
EOF

mkdir -p "$output"
dpkg-deb --root-owner-group --build "$package_root" "$output/$package"
(cd "$output" && sha256sum "$package" > "$package.sha256")
