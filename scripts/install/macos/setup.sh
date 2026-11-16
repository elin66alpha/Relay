#!/usr/bin/env bash
# macOS entry point. Linux and macOS share scripts/install/unix/setup.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../unix" && pwd -P)/setup.sh" "$@"
