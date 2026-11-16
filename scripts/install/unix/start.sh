#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

refuse_sudo start.sh
require_setup

if tunnel_enabled; then
  c_info "Starting the Relay backend and Cloudflare Tunnel"
else
  c_info "Starting the Relay backend"
fi
svc_start

c_info "Started. Check it with $(script_path status.sh)"
