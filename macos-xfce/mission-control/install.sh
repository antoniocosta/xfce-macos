#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# mission-control: macOS Mission Control (Spaces bar on top, the current desktop's windows below).
# Runs in the background from login; F3, Ctrl+Up and the bottom-right corner open it.
build_c "$HERE/mission-control.c" mission-control -lXcomposite -lcairo -lm
autostart_entry "Mission Control" "$BIN/mission-control --daemon"
(setsid "$BIN/mission-control" --daemon >/dev/null 2>&1 &)   # takes over from a running copy
ok "Mission Control (F3, Ctrl+Up, bottom-right corner)"
