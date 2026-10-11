#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# desktop-slide: the macOS slide between desktops. Builds picom (a compositor) from source, because
# the slide needs its v12+ animations and Mint ships v10; desktop-switch tells it which way to slide.
PICOM_TAG="v13"
if ! "$BIN/picom" --version 2>/dev/null | grep -q "^$PICOM_TAG "; then
    info "Building picom $PICOM_TAG (a few minutes)"
    mkd "$SRC"; track_file "$SRC/picom-$PICOM_TAG"; track_file "$BIN/picom"; rm -rf "$SRC/picom-$PICOM_TAG"
    git clone -q --depth=1 --branch "$PICOM_TAG" https://github.com/yshui/picom.git "$SRC/picom-$PICOM_TAG"
    (cd "$SRC/picom-$PICOM_TAG" && meson setup --buildtype=release build >/dev/null && ninja -C build >/dev/null)
    install -m 755 "$SRC/picom-$PICOM_TAG/build/src/picom" "$BIN/picom"
    ok "picom $PICOM_TAG installed"
fi
build_c "$HERE/desktop-switch.c" desktop-switch
install_bin "$HERE/desktop-slide"
[[ "$(install_file "$HERE/picom.conf" "$HOME/.config/picom/picom.conf")" == changed ]] && ok "Installed ~/.config/picom/picom.conf"
# "desktop-slide on" turns Xfce's own compositor off and starts picom at login
xf_record xfwm4 /general/use_compositing bool
track_file "$AUTOSTART/picom-slide.desktop"; mkd "$AUTOSTART"; track_proc picom
# First install: on. A re-run keeps your choice (Settings > Desktop & Dock can turn it off) and does not
# restart picom, which would flicker the screen: it only starts it if it should be running and is not.
slide_mark="$HOME/.config/xfce-macos/slide-set"
mkd "$(dirname "$slide_mark")"
if [[ -f "$AUTOSTART/picom-slide.desktop" ]]; then          # already on (this or an earlier install)
    touch "$slide_mark"
    pgrep -u "$USER" -x picom >/dev/null || "$BIN/desktop-slide" on >/dev/null
    ok "Desktop slide kept on"
elif [[ ! -f "$slide_mark" ]]; then                          # first install
    touch "$slide_mark"
    if "$BIN/desktop-slide" on >/dev/null; then
        ok "Desktop slide on (\`desktop-slide off\` goes back to Xfce's own compositor)"
    else
        warn "Desktop slide could not start picom: Xfce's own compositor stays on"
    fi
else
    ok "Desktop slide kept off (as you left it)"
fi
