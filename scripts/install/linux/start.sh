#!/usr/bin/env bash
# Linux entry point. Linux and macOS share scripts/install/unix/start.sh.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../unix" && pwd -P)/start.sh" "$@"
