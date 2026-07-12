#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

exec "$ROOT_DIR/scripts/setup.sh" "$@"
