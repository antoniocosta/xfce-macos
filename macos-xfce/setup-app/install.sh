#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# setup-app: a menu entry for the setup window ("Make Xfce feel like macOS": install, update, restore).
# It runs from this checkout, so keep the folder where it is.
icons="$HOME/.local/share/icons/hicolor/scalable/apps"
mkd "$icons"
install_file "$HERE/icon/xfce-macos-setup.svg" "$icons/xfce-macos-setup.svg" >/dev/null
apps="$HOME/.local/share/applications"; mkd "$apps"
track_file "$apps/xfce-macos-setup.desktop"
printf '[Desktop Entry]\nType=Application\nName=Make Xfce feel like macOS\nComment=Install, update or undo the macOS feel for Xfce\nIcon=xfce-macos-setup\nExec=%s\nTerminal=false\nCategories=XFCE;GTK;Settings;DesktopSettings;X-XFCE-SettingsDialog;X-XFCE-MacOSSettings;\nKeywords=macos;setup;install;restore;\n' \
    "$HERE/xfce-macos-setup" > "$apps/xfce-macos-setup.desktop"
update-desktop-database "$apps" 2>/dev/null || true
ok "Menu entry: Make Xfce feel like macOS (Setup)"
