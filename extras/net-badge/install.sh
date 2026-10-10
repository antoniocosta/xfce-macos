#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# net-badge: network latency in the top bar, like macOS's Network Badge app.
install_bin "$HERE/net-badge"
genmon="$(panel_plugin_id genmon)"
[[ -n "$genmon" ]] || genmon="$(panel_new_plugin genmon)"
mkdir -p "$HOME/.config/xfce4/panel"
printf 'Command=%s\nUseLabel=0\nText=\nUpdatePeriod=5000\nFont=Inter 10\n' "$BIN/net-badge" \
    > "$HOME/.config/xfce4/panel/genmon-$genmon.rc"
panel_apply_order
ok "Latency badge in the top bar (click it for details)"
