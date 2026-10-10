#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# fullscreen: macOS full screen. The green button goes full screen; in full screen, resting the
# pointer at the top edge brings the title bar back (red closes, green leaves full screen).
# Cmd+Ctrl+F toggles full screen for any window (Toshy keymap, set up by macos-xfce/install.sh).
build_c "$HERE/fullscreen.c" fullscreen -lXi -lcairo -lm
autostart_entry "Full Screen" "$BIN/fullscreen"
restart_bg fullscreen "$BIN/fullscreen"
ok "Full screen like macOS: green button, title bar at the top edge, Cmd+Ctrl+F"
