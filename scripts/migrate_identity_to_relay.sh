#!/usr/bin/env bash
# One-time identity migration for a clean public "Relay" release.
# Rewrites every functional identifier off the old "agentdeck" brand.
#
# Ordered, case-aware rules (most specific first):
#   dev.agentdeck.app          -> dev.relay.app      (applicationId / namespace /
#                                                           bundle id / kotlin package /
#                                                           MethodChannel)
#   dev.agentdeck.backend      -> dev.relay.app.backend   (macOS LaunchAgent label)
#   dev.agentdeck.tunnel       -> dev.relay.app.tunnel
#   dev.agentdeck              -> Relay                    (copyright / company name)
#   AGENTDECK_                 -> RELAY_                   (env var names)
#   agentDeck                  -> relay                    (FCM bg handler symbol)
#   agentdeck                  -> relay                    (catch-all: PM2 names, prefs
#                                                           keys, JS interop global, push
#                                                           tag, credential format/ext,
#                                                           Dart package name, binary name)
#
# Scope: version-controlled text files only (git ls-files), so node_modules/, build/,
# and gitignored runtime/secret stores are excluded. The kotlin source-dir move,
# server/.env keys, and google-services.json are handled OUTSIDE this script.
#
# Usage: scripts/migrate_identity_to_relay.sh [--apply]   (default = dry run)
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

mapfile -d '' files < <(git ls-files -z)

changed=0
for f in "${files[@]}"; do
  grep -Iqi 'agentdeck' "$f" 2>/dev/null || continue
  printf '  %s\n' "$f"
  changed=$((changed + 1))
  if [ "$APPLY" = "1" ]; then
    sed -i \
      -e 's/dev\.agentdeck\.app/dev.relay.app/g' \
      -e 's/dev\.agentdeck\.backend/dev.relay.app.backend/g' \
      -e 's/dev\.agentdeck\.tunnel/dev.relay.app.tunnel/g' \
      -e 's/dev\.agentdeck/Relay/g' \
      -e 's/AGENTDECK_/RELAY_/g' \
      -e 's/agentDeck/relay/g' \
      -e 's/agentdeck/relay/g' \
      "$f"
  fi
done

echo "----"
if [ "$APPLY" = "1" ]; then
  echo "Applied identity migration in $changed file(s)."
else
  echo "DRY RUN: $changed file(s) would change. Re-run with --apply."
fi
