#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PM2_APP_NAME="${PM2_APP_NAME:-relay-server}"
PM2_ECOSYSTEM="${PM2_ECOSYSTEM:-server/ecosystem.config.js}"
WEB_URL="${WEB_URL:-http://127.0.0.1:8787/}"
APK_PATH="${APK_PATH:-build/app/outputs/flutter-apk/app-debug.apk}"

run() {
  printf '\n==> %s\n' "$*"
  "$@"
}

wait_for_web() {
  printf '\n==> waiting for %s\n' "$WEB_URL"
  for attempt in {1..20}; do
    # Silence the expected "connection refused" while the freshly restarted
    # server is still binding the port; only the progress line is shown.
    if curl -fsS -I "$WEB_URL" >/dev/null 2>&1; then
      return 0
    fi
    printf 'web not ready yet (%s/20)\n' "$attempt"
    sleep 1
  done
  # All retries exhausted: surface the real error (server failed to come up).
  curl -sS -I "$WEB_URL"
}

restart_pm2_app() {
  printf '\n==> pm2 restart %s --update-env\n' "$PM2_APP_NAME"
  if pm2 restart "$PM2_APP_NAME" --update-env; then
    return 0
  fi

  printf 'pm2 restart failed; recreating %s from %s\n' "$PM2_APP_NAME" "$PM2_ECOSYSTEM"
  pm2 delete "$PM2_APP_NAME" >/dev/null 2>&1 || true
  pm2 start "$PM2_ECOSYSTEM" --only "$PM2_APP_NAME" --update-env
}

run flutter pub get
run flutter analyze --no-pub
run flutter test --no-pub

# Syntax-check every backend JS file (not a hand-maintained subset that silently
# skips new files), then run the server test suite. Both gate the build so a
# broken or regressed backend never ships.
for file in $(find server -name '*.js' -not -path '*/node_modules/*'); do
  run node --check "$file"
done
run npm --prefix server test

# --no-web-resources-cdn: bundle CanvasKit locally instead of loading it from
# gstatic.com. The CDN is unreachable on some networks (e.g. mainland China),
# which leaves the app loaded-but-blank. Serving it from our own backend over
# the tunnel keeps the web app fully self-hosted with zero external deps.
run flutter build web --no-pub --pwa-strategy=none --no-web-resources-cdn
restart_pm2_app
wait_for_web

run flutter build apk --debug --no-pub
if [[ "${INSTALL_APK:-0}" == "1" ]]; then
  run adb install -r "$APK_PATH"
else
  printf '\n==> APK built at %s (ADB install skipped; set INSTALL_APK=1 to install)\n' "$APK_PATH"
fi
