#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/lib/common.sh"

refuse_sudo stop.sh
svc_stop
c_info "Stopped. $(script_path start.sh) starts it again."
