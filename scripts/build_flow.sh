#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PM2_APP_NAME="${PM2_APP_NAME:-agentdeck-server}"
WEB_URL="${WEB_URL:-http://127.0.0.1:8787/}"
APK_PATH="${APK_PATH:-build/app/outputs/flutter-apk/app-debug.apk}"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

wait_for_web() {
  printf '\n==> waiting for %s\n' "$WEB_URL"
  for attempt in {1..20}; do
    if curl -fsS -I "$WEB_URL"; then
      return 0
    fi
    printf 'web not ready yet (%s/20)\n' "$attempt"
    sleep 1
  done
  curl -sS -I "$WEB_URL"
}

run flutter pub get
run flutter analyze --no-pub
run flutter test --no-pub

for file in \
  server/server.js \
  server/lib/history.js \
  server/lib/filesystem.js \
  server/lib/tokens.js \
  server/lib/credential-file.js \
  server/scripts/create-credential.js; do
  run node --check "$file"
done

# --no-web-resources-cdn: bundle CanvasKit locally instead of loading it from
# gstatic.com. The CDN is unreachable on some networks (e.g. mainland China),
# which leaves the app loaded-but-blank. Serving it from our own backend over
# the tunnel keeps the web app fully self-hosted with zero external deps.
run flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
run pm2 restart "$PM2_APP_NAME" --update-env
wait_for_web

run flutter build apk --debug --no-pub
run adb install -r "$APK_PATH"
