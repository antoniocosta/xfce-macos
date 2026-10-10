#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# auto-brightness: screen and keyboard backlight follow the room light, like macOS. Needs an
# ambient light sensor (MacBooks have one); does nothing without.
if ! ls /sys/bus/iio/devices/iio:device*/in_illuminance_* >/dev/null 2>&1; then
    info "No ambient light sensor here; auto-brightness skipped"; exit 0
fi
install_bin "$HERE/auto-brightness"
autostart_entry "Auto Brightness" "$BIN/auto-brightness"
[[ -f "$HOME/.config/auto-brightness.conf" ]] || printf '[auto-brightness]\nscreen = true\nkeyboard = true\n' > "$HOME/.config/auto-brightness.conf"
mkdir -p "$HOME/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Auto Brightness\nComment=Adjust screen and keyboard brightness automatically from the light sensor\nIcon=display-brightness\nExec=%s --settings\nCategories=XFCE;GTK;Settings;DesktopSettings;X-XFCE-SettingsDialog;X-XFCE-HardwareSettings;\n' \
    "$BIN/auto-brightness" > "$HOME/.local/share/applications/auto-brightness-settings.desktop"
restart_bg auto-brightness "$BIN/auto-brightness"
ok "Auto brightness on (Settings Manager → Auto Brightness to choose screen/keyboard)"
