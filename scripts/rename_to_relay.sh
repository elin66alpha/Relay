#!/usr/bin/env bash
# One-time global rebrand: brand display name AgentDeck -> Relay.
#
# CASE-SENSITIVE on purpose. Only the PascalCase brand token (A-g-e-n-t-D-e-c-k)
# is user-visible text; every FUNCTIONAL identifier deliberately uses a different
# casing and is left untouched:
#   - Dart package name .............. agentdeck   (package:agentdeck/...)
#   - bundle id / applicationId ...... dev.agentdeck.app
#   - PM2 process names .............. agentdeck-server / agentdeck-tunnel
#   - SharedPreferences keys ......... agentdeck.*.v1
#   - credential format / file ext ... agentdeck.credentials.v1 / *.agentdeck.json
#   - web push JS interop global ..... window.agentdeckPush
#   - notification grouping tag ...... 'agentdeck'
#   - Firebase admin app name ........ agentdeck-fcm
#   - FCM bg handler ................. agentDeckFcmBackgroundHandler
# None of those match /AgentDeck/, so they survive.
#
# Scope: only version-controlled, text files (git ls-files excludes node_modules/,
# build/, and every gitignored runtime/secret store such as chat-history*.json).
#
# Usage:
#   scripts/rename_to_relay.sh            # dry run: list files + line hit counts
#   scripts/rename_to_relay.sh --apply    # perform the replacement
set -euo pipefail
cd "$(dirname "$0")/.."

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

mapfile -d '' files < <(git ls-files -z)

changed=0
for f in "${files[@]}"; do
  # -I skips binary files; only touch files that actually contain the token.
  grep -Iq 'AgentDeck' "$f" 2>/dev/null || continue
  n=$(grep -Ic 'AgentDeck' "$f" || true)
  printf '  %-60s %s\n' "$f" "($n)"
  changed=$((changed + 1))
  if [ "$APPLY" = "1" ]; then
    sed -i 's/AgentDeck/Relay/g' "$f"
  fi
done

echo "----"
if [ "$APPLY" = "1" ]; then
  echo "Applied AgentDeck -> Relay in $changed file(s)."
else
  echo "DRY RUN: $changed file(s) would change. Re-run with --apply to write."
fi
