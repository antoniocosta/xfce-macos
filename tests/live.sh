#!/usr/bin/env bash
# Live tests: an invisible X display (Xvfb) with Xfce's window manager, its own D-Bus session and its
# own settings store, so nothing appears on your screen and nothing touches your settings. The
# programs are built from this checkout into a temporary folder. In there the tests move the
# pointer and click freely.
#   tests/live.sh [NAME]     run tests/live/*.sh (only those whose name contains NAME)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${LIVE_INSIDE:-}" ]]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp"/{home,config,state,bin,run}
    chmod 700 "$tmp/run"
    exec env -i PATH="$tmp/bin:/usr/local/bin:/usr/bin:/bin" HOME="$tmp/home" \
        XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" \
        LIVE_INSIDE=1 LIVE_TMP="$tmp" LIVE_KEEP_LOG="${LIVE_KEEP_LOG:-}" TERM="${TERM:-dumb}" \
        dbus-run-session -- bash "$0" "$@"
fi

. "$HERE/lib.sh"
T=$LIVE_TMP
BIN=$T/bin

# ---- build the programs from this checkout ----
gcc -O2 -o "$BIN/fullscreen"      "$ROOT/macos-xfce/fullscreen/fullscreen.c" -lX11 -lXi -lcairo -lm || exit 1
gcc -O2 -o "$BIN/mission-control" "$ROOT/macos-xfce/mission-control/mission-control.c" -lX11 -lXcomposite -lcairo -ljpeg -lm || exit 1
gcc -O2 -o "$BIN/idle-watch"      "$ROOT/macos-xfce/auto-brightness/idle-watch.c" -lX11 -lXext || exit 1
gcc -O2 -o "$BIN/hotcorner"       "$ROOT/macos-xfce/hotcorner/hotcorner.c" -lX11 || exit 1
gcc -O2 -o "$BIN/show-desktop"    "$ROOT/macos-xfce/hotcorner/show-desktop.c" -lX11 || exit 1
gcc -O2 -o "$BIN/desktop-switch"  "$ROOT/macos-xfce/desktop-slide/desktop-switch.c" -lX11 || exit 1

# ---- the invisible display and its window manager ----
for n in $(seq 90 120); do [[ -e /tmp/.X11-unix/X$n ]] || { DNUM=$n; break; }; done
Xvfb ":$DNUM" -screen 0 1440x900x24 -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
export DISPLAY=":$DNUM"
wait_until 5 xprop -root || { echo "Xvfb did not start"; exit 1; }
xfset() { xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4"; }
xfset xfwm4 /general/workspace_count int 4
xfset xfwm4 /general/button_layout string "CHM|"
xfset xfwm4 /general/wrap_workspaces bool false
xfset xfwm4 /general/use_compositing bool false
xfset xfwm4 /general/activate_action string switch
xfwm4 --compositor=off --sm-client-disable >"$LIVE_TMP/xfwm4.log" 2>&1 &
WM=$!
wait_until 10 bash -c 'xprop -root _NET_SUPPORTING_WM_CHECK | grep -q "window id"' || { echo "xfwm4 did not start"; exit 1; }
wait_until 10 bash -c 'xprop -root _NET_NUMBER_OF_DESKTOPS | grep -q "= 4"'
cleanup() {   # everything this run started: its own children only (by PID), then the display
    local p; for p in $(jobs -p) "$WM" "$XVFB"; do kill "$p" 2>/dev/null; done
    sleep 0.3
    for p in $(jobs -p) "$WM" "$XVFB"; do kill -9 "$p" 2>/dev/null; done   # a stuck one must not outlive the run
    wait 2>/dev/null
    rm -rf "$LIVE_TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP        # a timeout or Ctrl+C still runs cleanup

# ---- helpers for the tests ----
win_id() { xdotool search --name "^$1\$" 2>/dev/null | head -1; }
open_win() {  # open_win TITLE [win.py options]   (waits for it, prints its id)
    python3 -I "$HERE/win.py" "$@" >/dev/null 2>&1 &
    wait_until 8 bash -c "xdotool search --name '^$1\$' >/dev/null && wmctrl -l | grep -q ' $1\$'"
    sleep 0.3
    win_id "$1"
}
close_win() { [[ -n "$1" ]] && wmctrl -i -c "$1"; sleep 0.4; }
desk_of() { xprop -id "$1" _NET_WM_DESKTOP 2>/dev/null | awk '{print $3}'; }
ndesk()   { xprop -root _NET_NUMBER_OF_DESKTOPS | awk '{print $3}'; }
curdesk() { xprop -root _NET_CURRENT_DESKTOP | awk '{print $3}'; }
active()  { xprop -root _NET_ACTIVE_WINDOW | awk '{print $5}' | tr -d ,; }
is_full() { xprop -id "$1" _NET_WM_STATE 2>/dev/null | grep -q _NET_WM_STATE_FULLSCREEN; }
origin_of() { xprop -id "$1" _MACOS_FULLSCREEN_ORIGIN 2>/dev/null | awk '/= /{print $3}'; }
hex() { printf '0x%x' "$1"; }
set_desktops() { wmctrl -n "$1"; wait_until 3 bash -c "[ \$(xprop -root _NET_NUMBER_OF_DESKTOPS | awk '{print \$3}') = $1 ]"; }
go() { wmctrl -s "$1"; wait_until 3 bash -c "[ \$(xprop -root _NET_CURRENT_DESKTOP | awk '{print \$3}') = $1 ]"; }
mapped() { local w; w=$(xwininfo -root -tree | awk -v n="\"$1\"" 'index($0, n) {print $1; exit}'); [[ -n "$w" ]] && xwininfo -id "$w" | grep -q IsViewable; }
# test copies are stopped by their PID, never by name: that would also hit your real ones
start_fullscreen() { stop_fullscreen; FULLSCREEN_LOG="$LIVE_TMP/fullscreen.log" "$BIN/fullscreen" "$@" >>"$LIVE_TMP/fullscreen.log" 2>&1 & FS_PID=$!; sleep 0.5; kill -0 "$FS_PID" 2>/dev/null || echo "fullscreen died at start" >>"$LIVE_TMP/fullscreen.log"; }
stop_fullscreen()  { [[ -n "${FS_PID:-}" ]] && kill "$FS_PID" 2>/dev/null; FS_PID=; sleep 0.2; }
reset_desktops() {  # back to 4 empty desktops, desktop 1, no leftovers
    for w in $(wmctrl -l | awk '{print $1}'); do wmctrl -i -c "$w"; done
    sleep 0.6; set_desktops 4; go 0; rm -f "$XDG_STATE_HOME/fullscreen-spaces"
    xprop -root -remove _MACOS_PENDING_SPACES; xprop -root -remove _MACOS_LAYOUT_BUSY
}
export -f win_id desk_of ndesk curdesk active is_full origin_of mapped hex
export HERE BIN

for f in "$HERE"/live/*.sh; do
    [[ -n "${1:-}" && "$(basename "$f")" != *"$1"* ]] && continue
    . "$f"
done
[[ -n "${LIVE_KEEP_LOG:-}" ]] && cp "$LIVE_TMP"/*.log "$LIVE_KEEP_LOG"/ 2>/dev/null
t_summary
