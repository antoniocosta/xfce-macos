#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# settings: macOS-style pages in Xfce's Settings Manager, named like macOS's System Settings:
#   Desktop & Dock (Dock, Hot Corners, desktop slide), Trackpad, Displays, Keyboard.
# Each page applies changes as you make them; nothing runs after you close it.
install_bin "$HERE/macos-settings" "$HERE/settings_core.py"
# our own icons, so these entries are easy to tell from Xfce's own (Keyboard, Display, ...)
icons="$HOME/.local/share/icons/hicolor/scalable/apps"; mkd "$icons"
for f in "$HERE"/icons/*.svg; do install_file "$f" "$icons/$(basename "$f")" >/dev/null; done
apps="$HOME/.local/share/applications"; mkd "$apps"

entry() {  # entry FILE NAME PANE ICON CATEGORY COMMENT
    track_file "$apps/$1"
    printf '[Desktop Entry]\nType=Application\nName=%s\nComment=%s\nIcon=%s\nExec=%s/macos-settings %s\nTerminal=false\nCategories=XFCE;GTK;Settings;DesktopSettings;X-XFCE-SettingsDialog;%s;\nKeywords=macos;mac;settings;\n' \
        "$2" "$6" "$4" "$BIN" "$3" "$5" > "$apps/$1"
}
entry macos-settings-dock.desktop "Desktop & Dock" dock xfce-macos-dock X-XFCE-PersonalSettings \
    "Dock size, magnification and position, Hot Corners, sliding between desktops"
if xinput list --id-only >/dev/null 2>&1 && "$BIN/macos-settings" --apply; then
    entry macos-settings-trackpad.desktop "Trackpad" trackpad xfce-macos-trackpad X-XFCE-HardwareSettings \
        "Tap to click, natural scrolling, tracking and scrolling speed"
    # the scroll distance and tracking speed are not kept by Xfce: put them back at every login
    autostart_entry "Trackpad Settings" "$BIN/macos-settings --apply"
else
    rm -f "$apps/macos-settings-trackpad.desktop" "$AUTOSTART/trackpad-settings.desktop"
fi
if ls /sys/bus/iio/devices/iio:device*/in_illuminance_* >/dev/null 2>&1; then
    entry macos-settings-displays.desktop "Displays" displays xfce-macos-displays X-XFCE-HardwareSettings \
        "Automatically adjust brightness"
    ls /sys/class/leds/*kbd_backlight* >/dev/null 2>&1 && entry macos-settings-keyboard.desktop "Keyboard Brightness" keyboard \
        xfce-macos-keyboard X-XFCE-HardwareSettings "Keyboard brightness in low light"
fi
rm -f "$apps/auto-brightness-settings.desktop"      # replaced by the Displays and Keyboard pages
update-desktop-database "$apps" 2>/dev/null || true
ok "Settings pages: Desktop & Dock, Trackpad, Displays, Keyboard Brightness (Settings Manager)"
