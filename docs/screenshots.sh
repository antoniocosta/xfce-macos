#!/usr/bin/env bash
# docs/screenshots.sh: take the README screenshots from a neutral, private demo scene.
#
#   docs/screenshots.sh [STEP...]     steps: hero mission fullscreen settings   (default: all)
#   OUT=dir                           where the PNGs go (default docs/images)
#   SOURCE_HOME=dir                   where the installed look is read from, read-only (default: your home)
#
# Everything runs on a PRIVATE invisible X display (Xvfb) with its own D-Bus session, home folder and
# runtime folder: nothing shows on your screen and none of your settings, windows or processes are
# touched. The look (theme, icons, panel layout) is copied from the installed one; the content is demo
# content (a `$` prompt, example files, a stock wallpaper). It refuses to run if the display or the
# D-Bus session it ends up with is the real one. Needs: Xvfb dbus-run-session xfwm4 xfce4-panel xfdesktop
# xfsettingsd plank xfce4-terminal thunar xed wmctrl xdotool and python3 with PyGObject.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"

if [[ -z "${SHOTS_INSIDE:-}" ]]; then
    for c in Xvfb dbus-run-session xfwm4 xfce4-panel xfdesktop xfsettingsd plank xfce4-terminal thunar xed wmctrl xdotool gcc; do
        command -v "$c" >/dev/null || { echo "missing: $c" >&2; exit 1; }
    done
    tmp="$(mktemp -d)"
    mkdir -p "$tmp"/home/.config "$tmp"/home/.local/share "$tmp"/home/.local/bin "$tmp"/home/.local/state \
        "$tmp"/home/.cache "$tmp"/run "$tmp"/stub
    chmod 700 "$tmp/run"
    # nothing in here may reach your real processes or services, whatever a program tries
    for n in pkill killall systemctl sudo; do printf '#!/bin/sh\nexit 0\n' > "$tmp/stub/$n"; done
    printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/pgrep"
    chmod +x "$tmp"/stub/*
    disp=""
    for n in $(seq 95 140); do [[ -e /tmp/.X11-unix/X$n ]] || { disp=$n; break; }; done
    [[ -n "$disp" ]] || { echo "no free display number" >&2; exit 1; }
    mkdir -p "${OUT:-$HERE/images}"
    exec env -i PATH="$tmp/stub:$tmp/home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_DATA_HOME="$tmp/home/.local/share" \
        XDG_CACHE_HOME="$tmp/home/.cache" XDG_STATE_HOME="$tmp/home/.local/state" XDG_RUNTIME_DIR="$tmp/run" \
        XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_TYPE=x11 LANG=C.UTF-8 TERM=xterm \
        XDG_CONFIG_DIRS=/etc/xdg/xdg-xfce:/etc/xdg XDG_DATA_DIRS=/usr/share/xfce4:/usr/local/share:/usr/share \
        GTK_MODULES=appmenu-gtk-module UBUNTU_MENUPROXY=1 PS1='$ ' \
        SHOTS_INSIDE=1 SHOTS_TMP="$tmp" SHOTS_DISP="$disp" SRC_HOME="${SOURCE_HOME:-$HOME}" \
        KEEP_LOGS="${KEEP_LOGS:-}" OUT="$(cd "${OUT:-$HERE/images}" && pwd)" REAL_DISPLAY="${DISPLAY:-}" REAL_DBUS="${DBUS_SESSION_BUS_ADDRESS:-}" \
        dbus-run-session -- bash "$0" "$@"
fi

# ---- from here on we are inside the sandbox ----------------------------------------------------
T="$SHOTS_TMP"
PIDS=()
cleanup() {
    local p
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    sleep 0.5
    [[ -n "${KEEP_LOGS:-}" ]] && { mkdir -p "$KEEP_LOGS"; cp "$T"/*.log "$KEEP_LOGS"/ 2>/dev/null; }
    rm -rf "$T"
}
trap cleanup EXIT
die() { echo "STOP: $*" >&2; exit 1; }

[[ "$HOME" == "$T/home" ]] || die "HOME is not the sandbox's"
[[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" && "$DBUS_SESSION_BUS_ADDRESS" != "$REAL_DBUS" ]] || die "D-Bus session is the real one"

say() { printf '\033[1;35m== %s\033[0m\n' "$*"; }
wait_for() {  # wait_for SECONDS command...
    local tries=$(( $1 * 10 )); shift
    while (( tries-- > 0 )); do "$@" >/dev/null 2>&1 && return 0; sleep 0.1; done
    return 1
}
guard_display() {
    [[ "$DISPLAY" == ":$SHOTS_DISP" && "$DISPLAY" != "$REAL_DISPLAY" ]] || die "DISPLAY is not the sandbox's ($DISPLAY)"
}
win() { xdotool search --onlyvisible --name "$1" 2>/dev/null | head -1; }
win_class() { xdotool search --class "$1" 2>/dev/null | head -1; }
place() { wmctrl -i -r "$1" -e "0,$2,$3,$4,$5"; }       # place WINDOW X Y W H
shot() { guard_display; python3 "$ROOT/docs/capture.py" shot "$OUT/$1.png"; }

# ---- the programs we show, built from this checkout -------------------------------------------------
say "building"
gcc -O2 -o "$HOME/.local/bin/fullscreen" "$ROOT/macos-xfce/fullscreen/fullscreen.c" -lX11 -lXi -lcairo -lm || die "build"
gcc -O2 -o "$HOME/.local/bin/mission-control" "$ROOT/macos-xfce/mission-control/mission-control.c" \
    -lX11 -lXcomposite -lcairo -ljpeg -lm || die "build"
install -m 755 "$ROOT/macos-xfce/hotcorner/show-desktop" "$ROOT/macos-xfce/desktop-slide/desktop-switch" "$HOME/.local/bin/"

# ---- the look: copied (read-only) from the installed one ------------------------------------------
say "the look"
cp -r "$SRC_HOME/.themes" "$HOME/" 2>/dev/null
cp -r "$SRC_HOME/.local/share/icons" "$HOME/.local/share/" 2>/dev/null
mkdir -p "$HOME/.local/share/plank" && cp -r "$SRC_HOME/.local/share/plank/themes" "$HOME/.local/share/plank/" 2>/dev/null
mkdir -p "$HOME/.config/gtk-3.0" "$HOME/.config/xfce4/panel" "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
cp "$SRC_HOME/.config/gtk-3.0/gtk.css" "$HOME/.config/gtk-3.0/" 2>/dev/null
for ch in xsettings xfwm4 xfce4-panel xfce4-desktop; do
    cp "$SRC_HOME/.config/xfce4/xfconf/xfce-perchannel-xml/$ch.xml" "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/" 2>/dev/null
done
cp "$SRC_HOME"/.config/xfce4/panel/genmon-*.rc "$HOME/.config/xfce4/panel/" 2>/dev/null
cp "$SRC_HOME/.local/bin/net-badge" "$HOME/.local/bin/" 2>/dev/null
# neutral content
mkdir -p "$HOME/Documents/Projects" "$HOME/Documents/Photos" "$HOME/Downloads" "$HOME/Pictures" "$HOME/Music"
for f in "Meeting notes.txt" "Budget 2026.ods" "Trip plan.odt" "Recipe ideas.txt" "Reading list.md"; do : > "$HOME/Documents/$f"; done
printf 'Welcome\n\nThis is a demo document. Xfce, made to feel like macOS:\n  - Cmd shortcuts\n  - a menu bar and a Dock\n  - Mission Control, Spaces and hot corners\n\nLorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor\nincididunt ut labore et dolore magna aliqua.\n' > "$HOME/Documents/Welcome.txt"
printf "PS1='\$ '\n" > "$T/bashrc"
: > "$HOME/.sudo_as_admin_successful"                  # no Ubuntu sudo hint in the terminals
printf '$ ls Documents\nBudget 2026.ods  Photos     Recipe ideas.txt  Trip plan.odt\nMeeting notes.txt  Projects  Reading list.md  Welcome.txt\n$ \n' > "$T/term1.txt"
printf '$ uname -sr\nLinux 7.0\n$ echo "Spaces: one desktop per full-screen app"\nSpaces: one desktop per full-screen app\n$ \n' > "$T/term2.txt"

# ---- the display and the session -------------------------------------------------------------------------
say "starting the private display"
Xvfb ":$SHOTS_DISP" -screen 0 1440x900x24 -nolisten tcp >"$T/xvfb.log" 2>&1 &
PIDS+=($!)
export DISPLAY=":$SHOTS_DISP"
wait_for 10 xprop -root || die "Xvfb did not start"
guard_display
xfconf-query -c thunar -p /last-location-bar -n -t string -s ThunarLocationButtons
xfconf-query -c thunar -p /last-view -n -t string -s ThunarIconView
xfconf-query -c xfwm4 -p /general/workspace_count -n -t int -s 4
xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true     # shadows, without picom
xfconf-query -c xfce4-desktop -p /desktop-icons/style -n -t int -s 0      # no desktop icons in the pictures
wp=/usr/share/xfce4/backdrops/wallpapers_porioni_dark.jpg
[[ -e "$wp" ]] || wp="$(ls /usr/share/backgrounds/linuxmint*/*.jpg 2>/dev/null | head -1)"
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/last-image -n -t string -s "$wp"
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/image-style -n -t int -s 5
xfsettingsd >"$T/xfsettingsd.log" 2>&1 & PIDS+=($!)
sleep 1.5
xfwm4 >"$T/xfwm4.log" 2>&1 & PIDS+=($!)
wait_for 10 bash -c 'xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"' || die "xfwm4 did not start"
xfdesktop >"$T/xfdesktop.log" 2>&1 & PIDS+=($!)
xfce4-panel --disable-wm-check >"$T/panel.log" 2>&1 & PIDS+=($!)
# the Dock, with the neutral default items of the installer
mkdir -p "$HOME/.config/plank/dock1/launchers"
for f in "$ROOT"/macos-xfce/files/.config/plank/dock1/launchers/*.dockitem; do
    sed "s|@HOME@|$HOME|g" "$f" > "$HOME/.config/plank/dock1/launchers/$(basename "$f")"
done
dconf load /net/launchpad/plank/docks/dock1/ < "$ROOT/macos-xfce/files/plank-dock1.dconf"
sleep 3
dconf write /net/launchpad/plank/docks/dock1/hide-mode "'none'"
plank >"$T/plank.log" 2>&1 & PIDS+=($!)
FULLSCREEN_LOG="$T/fullscreen-trace.log" fullscreen >"$T/fullscreen.log" 2>&1 & PIDS+=($!)
mission-control --daemon >"$T/mc.log" 2>&1 & PIDS+=($!)
sleep 4

# ---- demo windows --------------------------------------------------------------------------------------------
term() {  # term TITLE FILE: a terminal with demo content and a plain prompt
    xfce4-terminal --disable-server --title="$1" --geometry=78x20 \
        -e "bash -c 'cat $2; exec bash --rcfile $T/bashrc -i'" >/dev/null 2>&1 &
    PIDS+=($!)
    wait_for 8 win "$1"
    sleep 0.4
}
open_scene() {
    guard_display
    term "Terminal" "$T/term1.txt"; TERM1=$(win "^Terminal$")
    thunar "$HOME/Documents" >/dev/null 2>&1 & PIDS+=($!)
    wait_for 10 win "Thunar$"; sleep 0.8; FILES=$(win "Thunar$")
    xed "$HOME/Documents/Welcome.txt" >/dev/null 2>&1 & PIDS+=($!)
    wait_for 10 win "Welcome.txt"; sleep 0.8; EDIT=$(win "Welcome.txt")
    term "Notes" "$T/term2.txt"; TERM2=$(win "^Notes$")
    wmctrl -i -r "$TERM2" -t 2; sleep 0.4
}

step_hero() {
    say "hero"
    wmctrl -s 0
    place "$TERM1" 60 60 700 330
    place "$FILES" 800 70 580 420
    place "$EDIT" 320 410 820 360
    wmctrl -i -a "$FILES"; sleep 0.3; wmctrl -i -a "$TERM1"; sleep 3
    xdotool mousemove 640 892; sleep 1.5                 # the pointer on the Dock: it magnifies, as on a Mac
    shot hero
    xdotool mousemove 700 300
}

step_mission() {
    say "mission control"
    wmctrl -i -r "$EDIT" -t 1; wmctrl -i -r "$TERM2" -t 2
    place "$TERM2" 200 150 760 420
    for d in 1 2 3 0; do wmctrl -s "$d"; sleep 2.6; done
    mission-control --open; sleep 2.2
    shot mission-control
    mission-control --close; sleep 0.6
}

step_fullscreen() {
    say "full screen"
    dconf write /net/launchpad/plank/docks/dock1/hide-mode "'auto'"                  # hidden until the edge, as in daily use
    wmctrl -s 1; sleep 0.5; wmctrl -i -a "$EDIT"; sleep 0.3
    wmctrl -i -r "$EDIT" -b add,fullscreen; sleep 2.5
    wmctrl -i -a "$EDIT"; sleep 1.2                       # the full-screen window has the focus
    xdotool mousemove 700 400; sleep 0.5; xdotool mousemove 700 0; sleep 0.15
    sleep 1
    shot fullscreen-menubar
    xdotool mousemove 700 400; sleep 1.5
    wmctrl -i -a "$EDIT"; sleep 1
    xdotool mousemove 720 899; sleep 2
    shot fullscreen-dock
    xdotool mousemove 700 400; sleep 0.8
    wmctrl -i -r "$EDIT" -b remove,fullscreen; sleep 2; wmctrl -s 0; sleep 1
    dconf write /net/launchpad/plank/docks/dock1/hide-mode "'none'"
}

step_settings() {
    say "settings pages"
    guard_display
    dconf write /net/launchpad/plank/docks/dock1/hide-mode "'auto'"                # the installer's defaults
    for pane in dock trackpad; do
        python3 "$ROOT/docs/capture.py" settings "$pane" "$OUT/settings-$pane.png"
    done
    python3 "$ROOT/docs/capture.py" setup "$OUT/setup-app.png"
    # Settings Manager with our own section
    mkdir -p "$HOME/.local/share/applications" "$HOME/.config/menus" "$HOME/.local/share/desktop-directories"
    cp "$SRC_HOME"/.local/share/applications/{macos-settings-*,xfce-macos-setup}.desktop "$HOME/.local/share/applications/" 2>/dev/null
    cp "$SRC_HOME/.config/menus/xfce-settings-manager.menu" "$HOME/.config/menus/" 2>/dev/null
    cp "$SRC_HOME/.local/share/desktop-directories/xfce-macos.directory" "$HOME/.local/share/desktop-directories/" 2>/dev/null
    printf '[Desktop Entry]\nType=Application\nName=hidden\nHidden=true\n' > "$HOME/.local/share/applications/xfdashboard-settings.desktop"
    xfce4-settings-manager >/dev/null 2>&1 & PIDS+=($!)
    wait_for 10 win "^Settings$"; sleep 2
    sm=$(win "^Settings$")
    wmctrl -i -r "$sm" -e "0,300,120,720,620"; sleep 1
    python3 "$ROOT/docs/capture.py" window "$OUT/settings-manager.png" "$sm"
    wmctrl -i -c "$sm"
}

steps=("$@"); [[ ${#steps[@]} -eq 0 ]] && steps=(hero mission fullscreen settings)
open_scene
for s in "${steps[@]}"; do guard_display; "step_$s"; done
say "done: $OUT"
ls -la "$OUT" | grep png
