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
    rm -rf "$SRC/picom-$PICOM_TAG"; mkdir -p "$SRC"
    git clone -q --depth=1 --branch "$PICOM_TAG" https://github.com/yshui/picom.git "$SRC/picom-$PICOM_TAG"
    (cd "$SRC/picom-$PICOM_TAG" && meson setup --buildtype=release build >/dev/null && ninja -C build >/dev/null)
    install -m 755 "$SRC/picom-$PICOM_TAG/build/src/picom" "$BIN/picom"
    ok "picom $PICOM_TAG installed"
fi
install_bin "$HERE/desktop-slide" "$HERE/desktop-switch"
[[ "$(install_file "$HERE/picom.conf" "$HOME/.config/picom/picom.conf")" == changed ]] && ok "Installed ~/.config/picom/picom.conf"
"$BIN/desktop-slide" on >/dev/null
ok "Desktop slide on (\`desktop-slide off\` goes back to Xfce's own compositor)"
