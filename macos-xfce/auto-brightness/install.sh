#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# auto-brightness: screen and keyboard backlight follow the room light, like macOS. Needs an
# ambient light sensor (MacBooks have one); does nothing without.
if ! ls /sys/bus/iio/devices/iio:device*/in_illuminance_* >/dev/null 2>&1; then
    info "No ambient light sensor here; auto-brightness skipped"; exit 0
fi
install_bin "$HERE/auto-brightness"
build_c "$HERE/idle-watch.c" idle-watch -lXext      # stands in for the kernel's screen state where there is none
# The light follows the screen to sleep, and the screen sleeps while the lock screen has the display. Then
# logind refuses to change the light ("Session is not in foreground"), so the user may change it directly:
# a udev rule (system file, sudo once) that gives group "input" (Toshy needs it anyway) write access.
RULE=/etc/udev/rules.d/90-xfce-macos-kbd-backlight.rules
if ls /sys/class/leds/*kbd_backlight* >/dev/null 2>&1 && ! cmp -s "$HERE/90-kbd-backlight.rules" "$RULE" 2>/dev/null; then
    track_sys "$RULE"
    if sudo install -m 644 "$HERE/90-kbd-backlight.rules" "$RULE" && sudo udevadm control --reload \
       && sudo udevadm trigger --subsystem-match=leds --action=change; then
        ok "Keyboard light: your user may change it directly, so it can follow the screen to sleep"
    else
        warn "Could not install $RULE (needs sudo): run this installer again from a terminal. Until then the keyboard light cannot follow the screen to sleep while the lock screen is showing"
    fi
fi
if ls /sys/class/leds/*kbd_backlight* >/dev/null 2>&1 && ! id -nG | tr ' ' '\n' | grep -qx input; then
    sudo usermod -aG input "$USER" && warn "Added you to the 'input' group: log out and back in once for the keyboard light to follow the screen" \
        || warn "Could not add you to the 'input' group (sudo usermod -aG input $USER)"
fi
autostart_entry "Auto Brightness" "$BIN/auto-brightness"
[[ -f "$HOME/.config/auto-brightness.conf" ]] || { track_file "$HOME/.config/auto-brightness.conf"; printf '[auto-brightness]\nscreen = true\nkeyboard = true\n' > "$HOME/.config/auto-brightness.conf"; }
# its settings are on the Displays and Keyboard pages (macos-xfce/settings)
restart_bg auto-brightness "$BIN/auto-brightness"
ok "Auto brightness on (Settings Manager → Displays and Keyboard)"
