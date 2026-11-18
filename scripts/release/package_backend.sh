#!/usr/bin/env bash
#
# Builds build/release/relay-backend-linux-macos-v<VERSION>.tar.gz: the committed
# backend sources and service adapters, without tests, dependencies or
# deployment state, plus the compiled Web client in app/shell/build/web.
#
#   ./scripts/release/package_backend.sh [output-dir]
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(node -p "require('./server/package.json').version")"
NAME="relay-backend-linux-macos-v$VERSION"
OUT_DIR="${1:-$ROOT_DIR/build/release}"
ARCHIVE="$OUT_DIR/$NAME.tar.gz"

[ ! -e "$ARCHIVE" ] || { echo "Archive already exists: $ARCHIVE" >&2; exit 1; }
# Sources come from HEAD and the Web client from the working tree; uncommitted
# edits would make the two disagree.
git diff --quiet HEAD || { echo "Commit or stash tracked changes first." >&2; exit 1; }

(cd app/shell && flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn)

mkdir -p "$OUT_DIR"
stage="$(mktemp -d)"
TAR="$stage/bundle.tar"
trap 'rm -rf "$stage"' EXIT
# shellcheck disable=SC2046 # one argument per tracked path
git archive --format=tar --prefix="$NAME/" -o "$TAR" HEAD $(git ls-tree -r --name-only HEAD |
  grep -E '^(LICENSE|README(\.zh-CN)?\.md|docs/(CHANGELOG|SECURITY|handbook|install(\.zh-CN)?)\.md|scripts/install/(linux|macos|unix)/(lib/)?[^/]+\.sh|server/(server\.js|ecosystem\.config\.js|package(-lock)?\.json|\.env\.example|\.gitignore)|server/(lib|routes|scripts)/.*\.js)$')
# Keep the launch command at the archive root, alongside server/ and scripts/.
mkdir -p "$stage/$NAME"
cat > "$stage/$NAME/install.sh" <<'LAUNCHER'
#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")"
exec ./scripts/install/unix/setup.sh install
LAUNCHER
chmod 755 "$stage/$NAME/install.sh"
tar --append -f "$TAR" -C "$stage" "$NAME/install.sh"
tar --append -f "$TAR" --transform "s,^app/,$NAME/app/," app/shell/build/web
gzip -9 -c "$TAR" >"$ARCHIVE"
(cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" >"$NAME.tar.gz.sha256")

echo "Archive: $ARCHIVE"
cat "$OUT_DIR/$NAME.tar.gz.sha256"
