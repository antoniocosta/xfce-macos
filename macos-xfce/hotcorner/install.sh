#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# hotcorner: macOS hot corners. Top right: show desktop; bottom right: Mission Control (set up by
# mission-control/). Change the corners in Settings > Desktop & Dock > Hot Corners.
build_c "$HERE/hotcorner.c" hotcorner
build_c "$HERE/show-desktop.c" show-desktop
install_bin "$HERE/hot-corners"
autostart_entry "Hot Corners" "$BIN/hot-corners"
track_proc hot-corners hotcorner
(setsid "$BIN/hot-corners" >/dev/null 2>&1 &)   # replaces any running copy itself
ok "Hot corners on (top right: show desktop, bottom right: Mission Control)"
