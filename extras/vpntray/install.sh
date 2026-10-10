#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# vpntray: a light top-bar panel for the VPN command-line tool (unofficial). Event-driven, no timers.
command -v adguardvpn-cli >/dev/null || warn "adguardvpn-cli not found yet: install it, vpntray needs it"
install_bin "$HERE/vpntray" "$HERE/vpntray_core.py" "$HERE/vpntray-askpass"
mkd "$BIN/icons" "$HOME/.local/share/icons/hicolor/scalable/status"
for f in "$HERE"/icons/*.svg; do track_file "$BIN/icons/$(basename "$f")"; track_file "$HOME/.local/share/icons/hicolor/scalable/status/$(basename "$f")"; done
install -m 644 "$HERE"/icons/*.svg "$BIN/icons/"
install -m 644 "$HERE"/icons/*.svg "$HOME/.local/share/icons/hicolor/scalable/status/"
autostart_entry "vpntray" "$BIN/vpntray --background"
restart_bg vpntray "$BIN/vpntray" --background
ok "vpntray in the top bar (click the shield, then Open panel; or run: vpntray)"
