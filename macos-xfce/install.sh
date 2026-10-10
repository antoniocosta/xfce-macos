#!/usr/bin/env bash
# ==============================================================================
# macos-xfce/install.sh
#
# Makes Linux Mint 22.x Xfce look and behave like macOS, as lightly as possible: Cmd-key
# shortcuts (Toshy), a menu bar with a global menu, a dock, Spotlight and Launchpad (rofi),
# Mission Control, hot corners, 3-finger desktop swipes (Touchégg) with the
# macOS slide, a macOS-like Cmd+Tab, the volume click, automatic brightness on Macs, and
# the SSH key unlocked from the login keyring like the Keychain. Each part has its own folder
# here and can also be installed alone with its install.sh. See the README for the full list.
#
# Usage:
#   ./install.sh                  everything (asks for sudo once, for packages)
#   ./install.sh --user           only what needs no sudo (packages already installed)
#   ./install.sh --trim           also switch off background services and remove apps that a
#                                 typical laptop doesn't need (see README: "Trim"); sudo
#   ./install.sh --english-only   also remove other languages' translations, help and manuals,
#                                 and keep future installs English-only; sudo
#   ./install.sh --help
#
# Safe to re-run: every step checks before it changes anything. Log out and back in after
# the first run (the global menu and Toshy need a fresh session).
# ==============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
FILES="$HERE/files"
. "$ROOT/lib/common.sh"
APPLE_CURSOR_TAG="v2.0.1"
WHITESUR_ICONS_TAG="2026-09-10"   # only its battery icons are used

is_mac()    { grep -qi apple /sys/class/dmi/id/sys_vendor 2>/dev/null; }
is_laptop() { ls /sys/class/power_supply/BAT* >/dev/null 2>&1; }

require_mint_xfce() {
    grep -q '^ID=linuxmint' /etc/os-release || die "This sets up Linux Mint; this is $(. /etc/os-release; echo "$PRETTY_NAME")."
    require_xfce
}

# ==============================================================================
# Packages (sudo)
# ==============================================================================
setup_packages() {
    section "Packages"
    local pkgs=(
        touchegg rofi wmctrl xdotool x11-utils       # gestures, launcher, window control
        xfce4-appmenu-plugin appmenu-gtk3-module appmenu-gtk2-module appmenu-registrar  # global menu
        fonts-inter sassc git curl unzip             # font, theme build
        mesa-utils vainfo                            # hardware video decoding check
        zram-tools                                   # compressed swap in RAM
    )
    local d p
    for d in hotcorner desktop-slide volume-feedback disk-label auto-brightness ssh-keyring fullscreen mission-control; do
        while read -r p; do pkgs+=("$p"); done < <(packages_of "$HERE/$d")
    done
    is_mac    && pkgs+=(mbpfan)                      # MacBook fan control
    is_mac && lspci -nn 2>/dev/null | grep -qiE 'Network controller.*Broadcom.*(BCM43(1|2|3|5|6)|14e4:43)' \
              && pkgs+=(broadcom-sta-dkms)           # MacBook Wi-Fi (the driver Mint's Driver Manager picks)
    is_laptop && pkgs+=(tlp)                         # battery life
    lspci 2>/dev/null | grep -qiE '(VGA|3D).*Intel' && pkgs+=(i965-va-driver)   # video decoding on older Intel GPUs
    if [[ ! -f /etc/apt/sources.list.d/zquestz.list ]]; then
        info "Adding the Plank Reloaded package source (zquestz)"
        curl -fsSL https://zquestz.github.io/ppa/ubuntu/KEY.gpg | sudo gpg --dearmor --yes -o /usr/share/keyrings/zquestz-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/zquestz-archive-keyring.gpg] https://zquestz.github.io/ppa/ubuntu ./" \
            | sudo tee /etc/apt/sources.list.d/zquestz.list >/dev/null
    fi
    dpkg-query -W plank 2>/dev/null | grep -q . && sudo apt-get remove -y plank   # conflicts with plank-reloaded
    sudo apt-get update -q
    sudo apt-get install -y "${pkgs[@]}" plank-reloaded
    is_mac    && sudo systemctl enable --now mbpfan
    is_laptop && sudo systemctl enable --now tlp
    # zram: compressed swap in RAM, used before the swap file; keeps a small-RAM machine responsive
    local zcfg=$'ALGO=zstd\nPERCENT=50\nPRIORITY=100'
    if [[ "$(cat /etc/default/zramswap 2>/dev/null)" != "$zcfg" ]]; then
        printf '%s\n' "$zcfg" | sudo tee /etc/default/zramswap >/dev/null
        sudo systemctl restart zramswap && ok "zram swap on (zstd, up to half the RAM)"
    fi
    ok "Packages installed"
}

# ==============================================================================
# Trim (opt-in, --trim): background services and preinstalled apps a laptop rarely needs (sudo)
# ==============================================================================
setup_trim_system() {
    section "Trim background services"
    local u
    # printing, kernel crash reports, the firmware-update check, Ubuntu's login news
    for u in cups.service cups.socket cups.path cups-browsed.service kerneloops.service fwupd-refresh.timer \
             motd-news.timer; do
        systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || continue
        [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == disabled && "$(systemctl is-active "$u")" != active ]] \
            || sudo systemctl disable --now "$u" 2>/dev/null || true
    done
    # mobile modem, firmware updates, GPU switching, colour profiles, Thunderbolt, a second syslog.
    # Masked, because D-Bus, udev or a socket would otherwise start them on demand.
    local mask=(ModemManager.service colord.service rsyslog.service syslog.socket)
    is_mac && mask+=(fwupd.service bolt.service)                       # Apple ships no firmware through fwupd
    [[ "$(lspci 2>/dev/null | grep -cE 'VGA|3D')" -le 1 ]] && mask+=(switcheroo-control.service)   # one GPU
    ls /sys/bus/iio/devices/iio:device*/in_accel_* >/dev/null 2>&1 || mask+=(iio-sensor-proxy.service)  # no rotation sensor
    for u in "${mask[@]}"; do
        systemctl list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || continue
        [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == masked ]] || sudo systemctl mask --now "$u"
    done
    # preinstalled apps: LibreOffice, Thunderbird, Calendar; unused themes (Yaru icons, Mint-L)
    local apps=()
    mapfile -t apps < <(dpkg-query -W -f='${Status} ${Package}\n' 'libreoffice*' 'thunderbird*' gnome-calendar \
        yaru-theme-icon mint-l-theme mint-l-icons 2>/dev/null | awk '$1=="install" && $3=="installed" {print $4}')
    if (( ${#apps[@]} )); then
        sudo apt-get purge -y "${apps[@]}" && sudo apt-get autoremove -y
    fi
    sudo apt-get clean   # downloaded copies of already-installed packages
    ok "Printing, crash reports, modem, colour profiles, extra syslog off; LibreOffice, Thunderbird, Calendar removed"
    info "A printer later? sudo systemctl enable --now cups cups-browsed"
}

setup_trim_user() {
    section "Trim user services"
    local u f
    # calendar/contacts back end (only GNOME Calendar used it) and its reminder popups
    for u in evolution-source-registry.service evolution-calendar-factory.service evolution-addressbook-factory.service; do
        [[ "$(systemctl --user is-enabled "$u" 2>/dev/null)" == masked ]] || systemctl --user mask --now "$u" >/dev/null 2>&1 || true
    done
    mkdir -p "$AUTOSTART"
    # tray icons: the printer applet (printing is off), System Reports (polls constantly; it's in
    # the menu), Toshy's (the keys work without it), and xiccd (colour profiles are off)
    for f in org.gnome.Evolution-alarm-notify print-applet mintreport xiccd; do
        printf '[Desktop Entry]\nType=Application\nName=%s\nHidden=true\n' "$f" > "$AUTOSTART/$f.desktop"
    done
    [[ -f "$AUTOSTART/Toshy_Tray.desktop" ]] && ! grep -q '^Hidden=true' "$AUTOSTART/Toshy_Tray.desktop" \
        && echo 'Hidden=true' >> "$AUTOSTART/Toshy_Tray.desktop"
    # GNOME Online Accounts (only the removed calendar/contacts used it): stop D-Bus starting it
    local dbus="$HOME/.local/share/dbus-1/services" n
    mkdir -p "$dbus"
    for n in org.gnome.OnlineAccounts org.gnome.Identity; do
        printf '[D-BUS Service]\nName=%s\nExec=/bin/false\n' "$n" > "$dbus/$n.service"
    done
    systemctl --user mask --now gvfs-goa-volume-monitor.service >/dev/null 2>&1 || true
    # PackageKit's debconf helper can busy-loop at 100% CPU for a minute after login; Mint's
    # own tools don't need it
    systemctl --user mask --now pk-debconf-helper.socket pk-debconf-helper.service >/dev/null 2>&1 || true
    for n in evolution-alarm xiccd mintreport-tray; do pkill -u "$USER" -x "$n" 2>/dev/null || true; done
    pkill -u "$USER" -f 'toshy_tray\.py|system-config-printer/applet\.py' 2>/dev/null || true
    ok "Calendar/contacts services, reminders and unneeded tray icons off"
}

# English only (opt-in, --english-only): other languages' app translations, help pages and
# manuals. The dpkg setting keeps future installs English-only; region formats (dates,
# numbers) are not affected.
setup_english_only() {
    section "English only"
    local cfg=/etc/dpkg/dpkg.cfg.d/90-english-only
    local want='# English only (linux-utilities macos-xfce): skip other languages'"'"' translations, help and manuals.
path-exclude=/usr/share/locale/*/LC_MESSAGES/*.mo
path-include=/usr/share/locale/en*/LC_MESSAGES/*.mo
path-exclude=/usr/share/help/*
path-include=/usr/share/help/C/*
path-include=/usr/share/help/en*
path-exclude=/usr/share/man/??/*
path-exclude=/usr/share/man/??_*/*
path-exclude=/usr/share/man/??.*/*
path-exclude=/usr/share/locale-langpack/*
path-include=/usr/share/locale-langpack/en*'
    if [[ "$(cat "$cfg" 2>/dev/null)" != "$want" ]]; then
        printf '%s\n' "$want" | sudo tee "$cfg" >/dev/null
        ok "Future installs and updates: English only"
    fi
    local before after
    before="$(du -sm /usr/share/locale /usr/share/help /usr/share/man 2>/dev/null | awk '{s+=$1} END{print s}')"
    # only language folders (xx, xx_YY, xx@variant, xx.charset), never English, C or man1..9
    sudo find /usr/share/locale /usr/share/help -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[a-z]{2,3}([_@.][A-Za-z0-9@._-]+)?' ! -name 'en*' -exec rm -rf {} +
    sudo find /usr/share/man -mindepth 1 -maxdepth 1 -type d \
        -regextype posix-extended -regex '.*/[a-z]{2}([_.][A-Za-z0-9._-]+)?' ! -name 'en*' -exec rm -rf {} +
    after="$(du -sm /usr/share/locale /usr/share/help /usr/share/man 2>/dev/null | awk '{s+=$1} END{print s}')"
    (( before > after )) && ok "Removed $((before - after)) MB of other languages' translations, help and manuals"
    return 0
}

# ==============================================================================
# Toshy (Cmd key like macOS)
# ==============================================================================
setup_toshy() {
    section "Toshy"
    if [[ ! -f "$HOME/.config/toshy/toshy_config.py" ]]; then
        info "Installing Toshy (asks for sudo; accept the defaults)"
        local tmp; tmp="$(mktemp -d)"
        curl -fsSL https://github.com/RedBearAK/toshy/archive/refs/heads/main.zip -o "$tmp/toshy.zip"
        unzip -q "$tmp/toshy.zip" -d "$tmp"
        (cd "$tmp"/[Tt]oshy-main && ./setup_toshy.py install)
        rm -rf "$tmp"
    fi
    local cfg="$HOME/.config/toshy/toshy_config.py" end="###  SLICE_MARK_END: user_apps  ###"
    grep -qF "$end" "$cfg" || die "Toshy config has no user_apps slice; cannot add the keymaps"
    local changed
    changed="$(toshy_block "$cfg" "macos-xfce" "$HERE/toshy-keymaps.py")"
    if [[ "$changed" == changed ]]; then
        systemctl --user restart toshy-config.service 2>/dev/null || true
        ok "Toshy keymaps added (Ctrl+arrows in terminals, Ctrl+Tab for tabs); Toshy restarted"
    else
        ok "Toshy keymaps already in place"
    fi

    # A white, monochrome tray icon like the macOS menu bar's, made from Toshy's own icon
    # (the command-key outline, without the rainbow). A Toshy reinstall puts the rainbow back.
    local icons="$HOME/.config/toshy/assets" theme="$HOME/.local/share/icons/hicolor/scalable/apps" f n=0 white
    mkdir -p "$icons/originals" "$theme"
    for f in toshy_app_icon_rainbow.svg toshy_app_icon_rainbow_inverse.svg toshy_app_icon_rainbow_inverse_grayscale.svg; do
        [[ -f "$icons/originals/$f" ]] || cp "$icons/$f" "$icons/originals/" 2>/dev/null || continue
        white="$(python3 -I - "$icons/originals/toshy_app_icon_rainbow.svg" <<'PY'
import re, sys
svg = open(sys.argv[1]).read()
d = re.search(r'<path[^>]*?\sd="([^"]+)"', svg, re.S).group(1)
print('<?xml version="1.0" encoding="UTF-8"?>\n'
      '<!-- Monochrome Toshy tray icon (white command symbol). Originals in originals/. -->\n'
      '<svg xmlns="http://www.w3.org/2000/svg" width="150" height="150" viewBox="0 0 150 150">\n'
      f'  <path d="{d}" fill="#ffffff" fill-opacity="1"/>\n</svg>')
PY
)"
        local d; for d in "$icons" "$theme"; do
            [[ "$(cat "$d/$f" 2>/dev/null)" == "$white" ]] || { printf '%s\n' "$white" > "$d/$f"; n=1; }
        done
    done
    if (( n )); then
        pkill -u "$USER" -f 'toshy_tray\.py' 2>/dev/null || true   # a python process: match its script name
        [[ -f "$AUTOSTART/Toshy_Tray.desktop" ]] && grep -q '^Hidden=true' "$AUTOSTART/Toshy_Tray.desktop" \
            || { sleep 0.5; (setsid "$BIN/toshy-tray" >/dev/null 2>&1 &); }
        ok "White Toshy tray icon installed"
    fi
}

# toshy_block CONFIG NAME KEYMAPS-FILE: put the keymaps in Toshy's user_apps slice, in a marked block
toshy_block() {
    python3 -I - "$1" "$3" "###  SLICE_MARK_END: user_apps  ###" "# >>> $TAG: $2" "# <<< $TAG: $2" <<'PY'
import sys, re, pathlib
cfg, keymaps, end, start_tag, end_tag = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text(), *sys.argv[3:]
block = f"{start_tag}\n{keymaps.rstrip()}\n{end_tag}\n\n"
text = cfg.read_text()
pattern = re.compile(re.escape(start_tag) + r".*?" + re.escape(end_tag) + r"\n*", re.DOTALL)
new = pattern.sub(lambda _: block, text) if pattern.search(text) else text.replace(end, block + end, 1)
if new != text:
    cfg.write_text(new); print("changed")
PY
}

# ==============================================================================
# Theme: WhiteSur (window theme), macOS cursors, Inter font, Mint icons, dark mode
# ==============================================================================
setup_theme() {
    section "Theme"
    if [[ ! -d "$HOME/.themes/WhiteSur-Dark-solid" ]]; then
        info "Building the WhiteSur GTK theme"
        local tmp; tmp="$(mktemp -d)"
        git clone -q --depth=1 https://github.com/vinceliuice/WhiteSur-gtk-theme.git "$tmp/gtk"
        (cd "$tmp/gtk" && ./install.sh -c dark -c light -l >/dev/null)
        rm -rf "$tmp"
    fi
    if [[ ! -d "$HOME/.local/share/icons/macOS/cursors" ]]; then
        # macOS cursors, recreated (ful1e5/apple_cursor): every shape, resize arrows included
        info "Installing the macOS cursors"
        local tmp; tmp="$(mktemp -d)"
        curl -fsSL "https://github.com/ful1e5/apple_cursor/releases/download/$APPLE_CURSOR_TAG/macOS.tar.xz" -o "$tmp/c.tar.xz"
        tar -xJf "$tmp/c.tar.xz" -C "$tmp"
        mkdir -p "$HOME/.local/share/icons"; cp -r "$tmp/macOS" "$HOME/.local/share/icons/macOS"
        rm -rf "$tmp"
    fi
    # also the default for apps and windows that don't read the desktop's cursor setting
    mkdir -p "$HOME/.icons/default"
    printf '[Icon Theme]\nName=default\nInherits=macOS\n' > "$HOME/.icons/default/index.theme"
    mkdir -p "$HOME/.local/share/plank/themes"
    [[ -d "$HOME/.local/share/plank/themes/WhiteSur-Dark" ]] \
        || cp -r "$HOME/.themes/WhiteSur-Dark-solid/plank" "$HOME/.local/share/plank/themes/WhiteSur-Dark"

    xfset xsettings /Net/ThemeName        string WhiteSur-Dark-solid
    setup_battery_icons
    xfset xsettings /Net/IconThemeName    string Mint-Y-Blue-macbattery
    xfset xsettings /Gtk/CursorThemeName  string macOS
    xfset xsettings /Gtk/FontName         string "Inter 10"
    xfset xfwm4 /general/theme            string WhiteSur-Dark-solid
    xfset xfwm4 /general/title_font       string "Inter Semi-Bold 10"
    xfset xfwm4 /general/title_alignment  string center
    xfset xfwm4 /general/button_layout    string "CHM|"     # close, minimize, maximize on the left
    xfset xsettings /Gtk/DecorationLayout string "close,minimize,maximize:"   # the same for apps that draw
                                                            # their own title bar (Firefox, GTK4 apps)
    xfset xfwm4 /general/show_dock_shadow bool   false
    # Firefox and GTK4 apps follow the desktop portal's dark/light preference, not the theme
    gsettings set org.x.apps.portal color-scheme 'prefer-dark'
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
    gsettings set org.gnome.desktop.interface gtk-theme 'WhiteSur-Dark-solid'
    # GTK4/libadwaita apps read these instead of Xfce's settings
    gsettings set org.gnome.desktop.interface cursor-theme 'macOS'
    gsettings set org.gnome.desktop.interface icon-theme 'Mint-Y-Blue-macbattery'
    gsettings set org.gnome.desktop.interface font-name 'Inter 10'
    ok "WhiteSur dark theme, macOS cursors, Inter font, Mint-Y icons (macOS battery), dark mode"
}

# Mint's own app icons, but with WhiteSur's horizontal (macOS-style) battery in the top bar: a
# small icon theme that only holds the battery icons and inherits everything else from Mint-Y-Blue.
# The icons come from WhiteSur's own installer (GPL-3.0), run into a temporary folder.
setup_battery_icons() {
    local dest="$HOME/.local/share/icons/Mint-Y-Blue-macbattery"
    [[ -f "$dest/.whitesur-$WHITESUR_ICONS_TAG" ]] && return 0
    info "Fetching WhiteSur's battery icons ($WHITESUR_ICONS_TAG)"
    local tmp s f; tmp="$(mktemp -d)"
    git clone -q --depth=1 --branch "$WHITESUR_ICONS_TAG" https://github.com/vinceliuice/WhiteSur-icon-theme.git "$tmp/src" 2>/dev/null
    mkdir -p "$tmp/out"; (cd "$tmp/src" && ./install.sh -d "$tmp/out" >/dev/null 2>&1)
    local st="$tmp/out/WhiteSur/status"
    [[ -d "$st/16" ]] || { rm -rf "$tmp"; warn "WhiteSur icons unavailable; keeping Mint's battery"; return 0; }
    rm -rf "$dest"; mkdir -p "$dest/status/scalable" "$dest/status/symbolic"
    for s in 16 22 32; do       # the 16 px drawings first; the larger sizes only fill gaps
        for f in "$st/$s"/battery-*.svg; do
            [[ -e "$dest/status/scalable/$(basename "$f")" ]] || cp -L "$f" "$dest/status/scalable/"
        done
    done
    cp -L "$st/symbolic"/battery-*.svg "$dest/status/symbolic/"
    cat > "$dest/index.theme" <<'EOF'
[Icon Theme]
Name=Mint-Y-Blue-macbattery
Comment=Mint-Y-Blue with WhiteSur's horizontal (macOS-style) battery icons
Inherits=Mint-Y-Blue,hicolor
Directories=status/symbolic,status/scalable

[status/symbolic]
Context=Status
Size=16
MinSize=8
MaxSize=512
Type=Scalable

[status/scalable]
Context=Status
Size=48
MinSize=8
MaxSize=512
Type=Scalable
EOF
    printf 'Battery icons from WhiteSur-icon-theme (https://github.com/vinceliuice/WhiteSur-icon-theme), GPL-3.0.\nOnly the battery icons; everything else is inherited from Mint-Y-Blue.\n' > "$dest/README"
    touch "$dest/.whitesur-$WHITESUR_ICONS_TAG"
    gtk-update-icon-cache -q -f "$dest" 2>/dev/null || true
    rm -rf "$tmp"
}

# ==============================================================================
# Window manager, Cmd+Tab switcher, popups (gtk.css)
# ==============================================================================
setup_window_manager() {
    section "Window manager"
    xfset xfwm4 /general/wrap_windows     bool true    # drag a window against a screen edge: it moves to the next desktop
    xfset xfwm4 /general/wrap_workspaces  bool false
    # One desktop to start with, like macOS: more come from Mission Control (+, or dragging a window
    # onto it) and stay until removed there. Only on the first run, and only while every window is
    # still on the first desktop (a fresh install); after that the number is yours.
    local mark="$HOME/.config/linux-utilities/desktops-set"
    if [[ ! -f "$mark" ]]; then
        if ! wmctrl -l | awk '$2 > 0 {found=1} END {exit !found}'; then
            xfset xfwm4 /general/workspace_count int 1
            ok "One desktop, like macOS (add more in Mission Control)"
        fi
        mkdir -p "$(dirname "$mark")"; touch "$mark"
    fi
    xfset xfwm4 /general/tile_on_move     bool false   # no half-screen snapping at the edges
    xfset xfwm4 /general/cycle_workspaces bool true    # Cmd+Tab lists windows of every desktop
    xfset xfwm4 /general/cycle_preview    bool false   # icons, not window previews
    xfset xfwm4 /general/cycle_draw_frame bool false   # no blue outline while switching
    xfset xfwm4 /general/activate_action  string switch   # a window asking for focus takes you to its
                                                       # desktop, like macOS, instead of being pulled to yours
    local changed
    changed="$(upsert_block "$HOME/.config/gtk-3.0/gtk.css" "/* >>> $TAG: macos-xfce */" \
        "/* <<< $TAG: macos-xfce */" "$(cat "$FILES/gtk3-overrides.css")")"
    if [[ "$changed" == changed ]]; then
        (setsid xfwm4 --replace >/dev/null 2>&1 &)   # xfwm4 keeps workspace_count current: a restart keeps the desktops
        pkill -u "$USER" -x xfce4-notifyd 2>/dev/null || true   # D-Bus restarts it on the next popup
        ok "Cmd+Tab switcher and popup styling applied (window manager restarted)"
    else
        ok "Window manager already set up"
    fi
}

# ==============================================================================
# Menu bar: menu · app menu ······ status icons · volume · battery · notifications · clock
# ==============================================================================
setup_panel() {
    section "Menu bar"
    local appmenu; appmenu="$(panel_plugin_id appmenu)"
    [[ -n "$appmenu" ]] || appmenu="$(panel_new_plugin appmenu)"
    xfset xfce4-panel "/plugins/plugin-$appmenu/bold-application-name" bool true
    xfset xfce4-panel "/plugins/plugin-$appmenu/compact-mode" bool false
    xfset xfce4-panel "/plugins/plugin-$appmenu/expand" bool true
    local sep; sep="$(panel_plugin_id separator)"
    [[ -n "$sep" ]] && { xfset xfce4-panel "/plugins/plugin-$sep/expand" bool true; xfset xfce4-panel "/plugins/plugin-$sep/style" uint 0; }
    xfset xfce4-panel /panels/panel-1/position  string "p=6;x=0;y=0"   # top
    xfset xfce4-panel /panels/panel-1/size      uint 28
    xfset xfce4-panel /panels/panel-1/icon-size uint 16
    local clock systray volume
    clock="$(panel_plugin_id clock)"; systray="$(panel_plugin_id systray)"; volume="$(panel_plugin_id pulseaudio)"
    if [[ -n "$clock" ]]; then
        xfset xfce4-panel "/plugins/plugin-$clock/digital-layout"      uint 3
        xfset xfce4-panel "/plugins/plugin-$clock/digital-time-format" string "%a %-d %b  %H:%M"
        xfset xfce4-panel "/plugins/plugin-$clock/digital-time-font"   string "Inter Medium 11"
        xfset xfce4-panel "/plugins/plugin-$clock/digital-date-font"   string "Inter 11"
    fi
    if [[ -n "$systray" ]]; then
        xfset xfce4-panel "/plugins/plugin-$systray/icon-size"      int 16
        xfset xfce4-panel "/plugins/plugin-$systray/symbolic-icons" bool true
    fi
    [[ -n "$volume" ]] && xfset xfce4-panel "/plugins/plugin-$volume/show-notifications" bool true
    if [[ -n "$systray" ]]; then
        xfset xfce4-panel "/plugins/plugin-$systray/show-frame" bool false
        # status icons in a fixed order, right to left as macOS adds them: power, Toshy status,
        # Wi-Fi, updates (newer status icons), then Bluetooth and Toshy (older tray icons)
        xfset_strings xfce4-panel "/plugins/plugin-$systray/known-items" "Toshy Tray Icon Undefined" blueman
        xfset_strings xfce4-panel "/plugins/plugin-$systray/known-legacy-items" \
            mintupdate.py "networkmanager applet" "toshy status indicator" xfce4-power-manager
    fi
    # one battery icon (the panel's), not a second one from the power manager
    xfset xfce4-power-manager /xfce4-power-manager/show-tray-icon bool false
    # notifications at the top right, like macOS; no "connected" or "networks available" pop-ups
    xfset xfce4-notifyd /notify-location string top-right
    gsettings set org.gnome.nm-applet disable-connected-notifications true 2>/dev/null || true
    gsettings set org.gnome.nm-applet suppress-wireless-networks-available true 2>/dev/null || true
    gsettings set com.linuxmint.updates hide-systray true 2>/dev/null || true   # update shield only when there are updates

    # Global menu: loaded through GTK_MODULES at login. (Switching it on live through
    # xsettings crashes running tray apps, so it only takes effect after logging in again.)
    upsert_block "$HOME/.xsessionrc" "# >>> $TAG: global menu" "# <<< $TAG: global menu" \
'export GTK_MODULES="${GTK_MODULES:+$GTK_MODULES:}appmenu-gtk-module"
export UBUNTU_MENUPROXY=1' >/dev/null
    xfset xsettings /Gtk/ShellShowsMenubar bool true
    xfset xsettings /Gtk/ShellShowsAppmenu bool true
    panel_apply_order
    ok "Menu bar at the top with the global menu, in macOS order"
}

# ==============================================================================
# Keyboard shortcuts (physical Ctrl arrives as Super in GUI apps under Toshy)
# ==============================================================================
setup_shortcuts() {
    section "Keyboard shortcuts"
    local k="xfce4-keyboard-shortcuts" shots="$HOME/Pictures/Screenshots"
    mkdir -p "$shots"
    xfset $k "/commands/custom/<Super>space"  string "rofi -show drun"                                        # Cmd+Space
    xfset $k "/commands/custom/Print"         string "xfce4-screenshooter -f -s $shots"                       # Cmd+Shift+3
    xfset $k "/commands/custom/<Alt>Print"    string "xfce4-screenshooter -r -s $shots"                       # Cmd+Shift+4
    xfset $k "/commands/custom/<Shift>Print"  string "xfce4-screenshooter"                                    # Cmd+Shift+5
    xfset $k "/commands/custom/<Super>Left"   string "$BIN/desktop-switch prev"                               # Ctrl+Left
    xfset $k "/commands/custom/<Super>Right"  string "$BIN/desktop-switch next"                               # Ctrl+Right
    xfset $k "/commands/custom/<Super>Up"     string "$BIN/mission-control"                                   # Ctrl+Up
    xfset $k "/commands/custom/XF86LaunchA"   string "$BIN/mission-control"                                   # F3
    xfset $k "/commands/custom/XF86LaunchB"   string "rofi -show drun -theme $HOME/.config/rofi/launchpad.rasi"  # F4
    # Ctrl alone must not open the Mint menu (it arrives as a lone Super key)
    xfconf-query -c $k -p "/commands/custom/Super_L" -r 2>/dev/null || true
    ok "Spotlight, screenshots, desktops, Mission Control, Launchpad"
}

# ==============================================================================
# Desktop icons: disks and servers, top right
# ==============================================================================
setup_desktop_icons() {
    section "Desktop icons"
    local d=xfce4-desktop k
    # File System's own icon is replaced by disk-label's "Macintosh HD / 91 GB free"
    xfset $d /desktop-icons/style int 2                     # file and drive icons on the desktop
    xfset $d /desktop-icons/file-icons/show-filesystem bool false
    for k in show-removable show-device-removable show-network-removable show-unknown-removable; do
        xfset $d "/desktop-icons/file-icons/$k" bool true
    done
    xfset $d /desktop-icons/file-icons/show-home  bool false
    xfset $d /desktop-icons/file-icons/show-trash bool false
    if [[ "$(xfconf-query -c $d -p /desktop-icons/gravity 2>/dev/null)" != 2 ]]; then
        xfset $d /desktop-icons/gravity int 2    # arrange from the top right, in columns
        xfdesktop --arrange || true
    fi
    "$HERE/disk-label/install.sh"
}

# ==============================================================================
# Mission Control, Launchpad and Spotlight (rofi), gestures, and the utilities
# ==============================================================================
setup_helpers() {
    section "Mission Control, gestures, utilities"
    # retired: skippy-xd, the previous Mission Control (replaced by mission-control/)
    pkill -u "$USER" -x skippy-xd 2>/dev/null || true
    rm -rf "$BIN/skippy-xd" "$SRC/skippy-xd-stable" "$HOME/.config/skippy-xd"

    local f
    for f in .config/rofi/config.rasi .config/rofi/launchpad.rasi .config/touchegg/touchegg.conf; do
        [[ "$(install_file "$FILES/$f" "$HOME/$f")" == changed ]] && ok "Installed ~/$f"
    done
    # Touchégg's client can crash when it starts at login and then stays dead: run it through a
    # wrapper that restarts it (same name as the system autostart entry, so it replaces it)
    install_bin "$HERE/touchegg-client"
    mkdir -p "$AUTOSTART"
    printf '[Desktop Entry]\nType=Application\nName=Touchégg (gesture client, restarted if it exits)\nExec=%s\nX-GNOME-Autostart-enabled=true\n' \
        "$BIN/touchegg-client" > "$AUTOSTART/touchegg.desktop"
    (setsid "$BIN/touchegg-client" >/dev/null 2>&1 &)   # replaces any running client; reloads the config

    local u
    for u in mission-control hotcorner desktop-slide volume-feedback auto-brightness fullscreen; do "$HERE/$u/install.sh"; done
    # the SSH key unlocked at login from the login keyring, like the macOS Keychain
    [[ -f "$HOME/.ssh/id_ed25519" ]] && "$HERE/ssh-keyring/install.sh"
    return 0
}

# ==============================================================================
# Dock (Plank Reloaded)
# ==============================================================================
setup_dock() {
    section "Dock"
    local dir="$HOME/.config/plank/dock1/launchers" f item items=()
    mkdir -p "$dir"
    for f in "$FILES"/.config/plank/dock1/launchers/*.dockitem; do
        [[ -f "$dir/$(basename "$f")" ]] || install_file "$f" "$dir/$(basename "$f")" >/dev/null
    done
    # the dock keeps your own items after the first run; only a new dock gets the default set
    if [[ -z "$(dconf read /net/launchpad/plank/docks/dock1/dock-items 2>/dev/null)" ]]; then
        for item in $(grep -oE "'[^']+\.dockitem'" "$FILES/plank-dock1.dconf" | tr -d "'"); do
            local target; target="$(grep -m1 '^Launcher=' "$dir/$item" 2>/dev/null | sed 's|^Launcher=file://||')"
            [[ -z "$target" || -e "$target" || "$item" =~ ^(separator|applications|trash|desktop)\.dockitem$ ]] \
                && items+=("'$item'") || warn "Dock: skipped $item ($target is not on this machine)"
        done
        sed "s|^dock-items=.*|dock-items=[$(IFS=,; echo "${items[*]}" | sed "s/,/, /g")]|" "$FILES/plank-dock1.dconf" \
            | dconf load /net/launchpad/plank/docks/dock1/
    else
        grep -v '^dock-items=' "$FILES/plank-dock1.dconf" | dconf load /net/launchpad/plank/docks/dock1/
    fi
    autostart_entry "Plank" "plank"
    pgrep -u "$USER" -x plank >/dev/null || (setsid plank >/dev/null 2>&1 &)
    ok "Dock set up"
}

# ==============================================================================
# Apps: Firefox, hardware video decoding
# ==============================================================================
setup_apps() {
    section "Apps"
    # Hardware video decoding: older Intel GPUs (Sandy/Ivy Bridge, Haswell) only work with the
    # i965 VA-API driver; libva tries the newer iHD one first, which fails on them
    if vainfo 2>&1 | grep -q 'iHD.*init failed' && LIBVA_DRIVER_NAME=i965 vainfo >/dev/null 2>&1; then
        upsert_block "$HOME/.xsessionrc" "# >>> $TAG: video" "# <<< $TAG: video" \
'# the GPU decodes video through the i965 VA-API driver (the newer iHD one fails here)
export LIBVA_DRIVER_NAME=i965' >/dev/null && ok "Video decoding uses the i965 driver (from the next login)"
    fi
    local vaapi=""
    if vainfo >/dev/null 2>&1 || LIBVA_DRIVER_NAME=i965 vainfo >/dev/null 2>&1; then
        vaapi='
// Hardware video decoding (VA-API); for YouTube on older GPUs add the enhanced-h264ify extension
user_pref("media.ffmpeg.vaapi.enabled", true);
user_pref("media.hardware-video-decoding.force-enabled", true);'
    fi

    # Firefox: macOS-like trackpad scrolling speed, leaner, no telemetry; in the default profile
    local ini prof
    for ini in "$HOME/.config/mozilla/firefox/profiles.ini" "$HOME/.mozilla/firefox/profiles.ini"; do
        [[ -f "$ini" ]] || continue
        prof="$(awk -F= '/^\[Install/{i=1} i && /^Default=/{print $2; exit}' "$ini")"
        [[ -n "$prof" && -d "$(dirname "$ini")/$prof" ]] || continue
        upsert_block "$(dirname "$ini")/$prof/user.js" "// >>> $TAG: macos-xfce" "// <<< $TAG: macos-xfce" \
'// Slower trackpad scrolling (default 100). Lower = slower.
user_pref("mousewheel.default.delta_multiplier_x", 50);
user_pref("mousewheel.default.delta_multiplier_y", 50);

// Full screen keeps the tabs and toolbars (the whole browser goes full screen, as on macOS)
user_pref("browser.fullscreen.autohide", false);

// Leaner on a small laptop: fewer tab processes (site isolation stays on)
user_pref("dom.ipc.processCount", 4);
// unload background tabs when memory runs low (they reload when clicked, like Safari)
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.low_commit_space_threshold_mb", 600);
// smaller in-memory cache (default grows with RAM)
user_pref("browser.cache.memory.capacity", 65536);
// no telemetry, studies or sponsored new-tab content running in the background
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("app.shield.optoutstudies.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);
user_pref("browser.newtabpage.activity-stream.showSponsored", false);
user_pref("browser.newtabpage.activity-stream.showSponsoredTopSites", false);
user_pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);'"$vaapi" >/dev/null
        ok "Firefox: macOS-like scrolling, leaner memory${vaapi:+, hardware video decoding} (profile $prof; restart Firefox)"
    done
}

usage() { sed -n '/^# Usage:/,/^# =====/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

main() {
    local user_only=0 trim=0 english=0 a
    for a in "$@"; do
        case "$a" in
            --user) user_only=1 ;;
            --trim) trim=1 ;;
            --english-only) english=1 ;;
            -h|--help|help) usage; exit 0 ;;
            *) warn "Unknown option: $a"; usage; exit 1 ;;
        esac
    done
    require_mint_xfce
    if (( ! user_only )); then
        setup_packages
        (( trim )) && setup_trim_system
        (( english )) && setup_english_only
    fi
    setup_toshy; setup_theme; setup_window_manager; setup_panel; setup_shortcuts
    setup_desktop_icons; setup_helpers; setup_dock; setup_apps
    (( trim )) && setup_trim_user
    section "Done"
    ok "Set up. Log out and back in once so the global menu and Toshy start cleanly."
}

main "$@"
