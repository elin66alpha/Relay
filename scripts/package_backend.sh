#!/usr/bin/env bash
#
# Builds build/release/relay-backend-setup-v<VERSION>.tar.gz: the committed
# backend sources and service adapters, without tests, dependencies or
# deployment state, plus the compiled Web client in build/web.
#
#   ./scripts/package_backend.sh [output-dir]
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(node -p "require('./server/package.json').version")"
NAME="relay-backend-setup-v$VERSION"
OUT_DIR="${1:-$ROOT_DIR/build/release}"
ARCHIVE="$OUT_DIR/$NAME.tar.gz"

[ ! -e "$ARCHIVE" ] || { echo "Archive already exists: $ARCHIVE" >&2; exit 1; }
# Sources come from HEAD and the Web client from the working tree; uncommitted
# edits would make the two disagree.
git diff --quiet HEAD || { echo "Commit or stash tracked changes first." >&2; exit 1; }

flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn

mkdir -p "$OUT_DIR"
TAR="$(mktemp)"
trap 'rm -f "$TAR"' EXIT
# shellcheck disable=SC2046 # one argument per tracked path
git archive --format=tar --prefix="$NAME/" -o "$TAR" HEAD $(git ls-tree -r --name-only HEAD |
  grep -E '^(CHANGELOG\.md|LICENSE|README(\.zh-CN)?\.md|SECURITY\.md|docs/handbook\.md|scripts/setup\.sh|backends/README(\.zh-CN)?\.md|backends/(linux|macos)/(lib/)?[^/]+\.sh|backends/windows/(lib/)?[^/]+\.ps1|server/(server\.js|ecosystem\.config\.js|package(-lock)?\.json|\.env\.example|\.gitignore)|server/(lib|routes|scripts)/.*\.js)$')
tar --append -f "$TAR" --transform "s,^build/,$NAME/build/," build/web
gzip -9 -c "$TAR" >"$ARCHIVE"
(cd "$OUT_DIR" && sha256sum "$NAME.tar.gz" >"$NAME.tar.gz.sha256")

echo "Archive: $ARCHIVE"
cat "$OUT_DIR/$NAME.tar.gz.sha256"
