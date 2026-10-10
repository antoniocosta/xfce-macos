#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# volume-feedback: the macOS click when the volume changes.
install_bin "$HERE/volume-feedback"
autostart_entry "Volume Feedback" "$BIN/volume-feedback"
restart_bg volume-feedback "$BIN/volume-feedback"
ok "Volume click on"
