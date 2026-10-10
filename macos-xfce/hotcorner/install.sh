#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# hotcorner: macOS hot corners. Top right: show desktop; bottom right: Mission Control (skippy-xd,
# set up by macos-xfce/). Change the corners in ~/.local/bin/hot-corners.
build_c "$HERE/hotcorner.c" hotcorner
install_bin "$HERE/hot-corners"
autostart_entry "Hot Corners" "$BIN/hot-corners"
(setsid "$BIN/hot-corners" >/dev/null 2>&1 &)   # replaces any running copy itself
ok "Hot corners on (top right: show desktop, bottom right: Mission Control)"
