# mission-control: opening, the Spaces bar, moving windows, adding/removing/reordering desktops
# (sourced by live.sh). Positions come from MISSION_CONTROL_LAYOUT, which it writes on every redraw.

export MISSION_CONTROL_LAYOUT="$LIVE_TMP/mc-layout"
mc() { "$BIN/mission-control" "$@"; }
mc_open() { mc --open; wait_until 3 test -f "$MISSION_CONTROL_LAYOUT"; sleep 0.3; }
lay() { cat "$MISSION_CONTROL_LAYOUT" 2>/dev/null; }
desk_center() { lay | awk -v d="$1" '$1=="desk" && $2==d {printf "%d %d", $3 + $5/2, $4 + $6/2}'; }
desk_corner() { lay | awk -v d="$1" '$1=="desk" && $2==d {printf "%d %d", $3 + 1, $4 + 1}'; }
plus_center() { lay | awk '$1=="plus" {printf "%d %d", $2 + $4/2, $3 + $5/2}'; }
item_center() { lay | awk -v w="$1" '$1=="item" && $2==w {printf "%d %d", $3 + $5/2, $4 + $6/2}'; }
drag() {  # drag X1 Y1 X2 Y2: press, move in steps, release
    xdotool mousemove "$1" "$2" mousedown 1; sleep 0.1
    for i in 1 2 3 4 5 6 7 8; do
        xdotool mousemove $(( $1 + ($3 - $1) * i / 8 )) $(( $2 + ($4 - $2) * i / 8 )); sleep 0.05
    done
    sleep 0.1; xdotool mouseup 1; sleep 0.5
}
click_at() { xdotool mousemove "$1" "$2"; sleep 0.15; xdotool click 1; sleep 0.5; }

"$BIN/mission-control" --daemon >/dev/null 2>&1 & MC_PID=$!; sleep 0.5

t_begin "mission-control: opens and closes"
reset_desktops
A=$(open_win mc-a); B=$(open_win mc-b)
mc_open
check "opens (--open)"                     test -f "$MISSION_CONTROL_LAYOUT"
eq "shows the 4 desktops"                  "$(lay | grep -c '^desk ')" 4
eq "shows this desktop's 2 windows"        "$(lay | grep -c '^item ')" 2
check "has a +"                            bash -c "grep -q '^plus ' '$MISSION_CONTROL_LAYOUT'"
mc --close; sleep 0.3
check "closes (--close)"                   bash -c "! test -f '$MISSION_CONTROL_LAYOUT'"
mc; wait_until 3 test -f "$MISSION_CONTROL_LAYOUT"; mc; sleep 0.4
check "toggles"                            bash -c "! test -f '$MISSION_CONTROL_LAYOUT'"

t_begin "mission-control: click a window to go to it"
mc_open
read -r x y <<<"$(item_center "$(hex "$B")")"; click_at "$x" "$y"
check "closed"                             bash -c "! test -f '$MISSION_CONTROL_LAYOUT'"
eq "that window is active"                 "$(active)" "$(hex "$B")"

t_begin "mission-control: click a desktop to switch to it"
mc_open
read -r x y <<<"$(desk_center 2)"; click_at "$x" "$y"
eq "on desktop 3"                          "$(curdesk)" 2
go 0

t_begin "mission-control: drag a window onto a desktop moves it there"
mc_open
read -r x1 y1 <<<"$(item_center "$(hex "$A")")"; read -r x2 y2 <<<"$(desk_center 3)"
drag "$x1" "$y1" "$x2" "$y2"
eq "the window is on desktop 4"            "$(desk_of "$A")" 3
eq "still open, one window left here"      "$(lay | grep -c '^item ')" 1
mc --close; sleep 0.3

t_begin "mission-control: + adds a desktop; dragging a window onto + gives it one"
mc_open
read -r x y <<<"$(plus_center)"; click_at "$x" "$y"
eq "5 desktops"                            "$(ndesk)" 5
read -r x1 y1 <<<"$(item_center "$(hex "$B")")"; read -r x2 y2 <<<"$(plus_center)"
drag "$x1" "$y1" "$x2" "$y2"
eq "6 desktops"                            "$(ndesk)" 6
eq "the window is on the new one"          "$(desk_of "$B")" 5
mc --close; sleep 0.3

t_begin "mission-control: the x on a desktop removes it; its windows go to the neighbour"
# now: A on desktop 3, B on desktop 5 (of 0..5)
mc_open
read -r x y <<<"$(desk_corner 3)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
eq "5 desktops"                            "$(ndesk)" 5
eq "its window went to the desktop before" "$(desk_of "$A")" 2
eq "later windows moved down one"          "$(desk_of "$B")" 4
mc --close; sleep 0.3

t_begin "mission-control: drag a desktop along the bar to reorder; windows go with it"
# A on 2, B on 4: drag desktop 2 to the end
mc_open
read -r x1 y1 <<<"$(desk_center 2)"; read -r x2 y2 <<<"$(desk_center 4)"
drag "$x1" "$y1" $((x2 + 30)) "$y2"
eq "A's desktop is now the last"           "$(desk_of "$A")" 4
eq "B moved one to the left"               "$(desk_of "$B")" 3
eq "still 5 desktops"                      "$(ndesk)" 5
mc --close; sleep 0.3

t_begin "mission-control: full-screen apps are only in the bar; from a Space it shows the app's desktop"
reset_desktops; start_fullscreen
A=$(open_win mc-a); F=$(open_win mc-full)
wmctrl -i -r "$A" -t 1; wmctrl -i -r "$F" -t 1; go 1; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 2 ]"; sleep 0.3
mc_open
eq "opened on the Space"                   "$(lay | awk '$1=="cur"{print $2}')" 2
eq "showing desktop 2, where the app came from" "$(lay | awk '$1=="view"{print $2}')" 1
eq "only the other window"                 "$(lay | awk '$1=="item"{print $2}')" "$(hex "$A")"
eq "the Space is named after the app"      "$(lay | awk '$1=="desk" && $2==2 {print $8}')" "Win.py"   # the test window's app
mc --close; sleep 0.6
eq "nothing chosen: back in the app"       "$(curdesk)" 2
wmctrl -i -r "$F" -b remove,fullscreen; sleep 1; stop_fullscreen

t_begin "mission-control: removing the first desktop sends its windows to the right one"
reset_desktops
A=$(open_win mc-a); B=$(open_win mc-b); C=$(open_win mc-c)
wmctrl -i -r "$A" -t 0; wmctrl -i -r "$B" -t 1; wmctrl -i -r "$C" -t 2; go 0
mc_open
read -r x y <<<"$(desk_corner 0)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
eq "3 desktops"                            "$(ndesk)" 3
eq "its window went in with desktop 2's"  "$(desk_of "$A")" 0
eq "desktop 2's window is first now"       "$(desk_of "$B")" 0
eq "later windows moved down one"          "$(desk_of "$C")" 1
mc --close; sleep 0.3

t_begin "mission-control: a minimized window moves with its desktop"
reset_desktops
A=$(open_win mc-a); M=$(open_win mc-min); C=$(open_win mc-c)
wmctrl -i -r "$A" -t 1; wmctrl -i -r "$M" -t 2; wmctrl -i -r "$C" -t 3; go 2; xdotool windowminimize "$M"; sleep 0.5; go 0
mc_open
read -r x y <<<"$(desk_corner 1)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
eq "the minimized window moved down one"   "$(desk_of "$M")" 1
eq "and the one after it"                  "$(desk_of "$C")" 2
mc --close; sleep 0.3

t_begin "mission-control: a desktop moves together with its full-screen Space"
reset_desktops; start_fullscreen
A=$(open_win mc-a); F=$(open_win mc-full); B=$(open_win mc-b)
wmctrl -i -r "$A" -t 0; wmctrl -i -r "$F" -t 1; wmctrl -i -r "$B" -t 3; go 1; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 2 ]"; sleep 0.5; go 0
mc_open
read -r x1 y1 <<<"$(desk_center 1)"; read -r x2 y2 <<<"$(desk_center 4)"
drag "$x1" "$y1" $((x2 + 30)) "$y2"
eq "the Space moved with its desktop"      "$(desk_of "$F")" 4
eq "and still comes right after it"        "$(origin_of "$F")" 3
eq "the window of the last desktop moved up" "$(desk_of "$B")" 2
mc --close; sleep 0.8
eq "the app is still full screen"          "$(is_full "$F" && echo yes)" yes
wmctrl -i -r "$F" -b remove,fullscreen
wait_until 4 bash -c "[ \$(ndesk) = 4 ]"; sleep 0.5
eq "leaving full screen goes back to its desktop" "$(desk_of "$F")" 3
stop_fullscreen

t_begin "mission-control: a desktop with a full-screen Space after it can be removed; the Space follows the one before"
reset_desktops; start_fullscreen
A=$(open_win mc-a); F=$(open_win mc-full); B=$(open_win mc-b)
wmctrl -i -r "$A" -t 0; wmctrl -i -r "$F" -t 1; wmctrl -i -r "$B" -t 3; go 1; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 2 ]"; sleep 0.5; go 0
eq "five desktops: 0, 1, its Space 2, 3, 4" "$(ndesk)" 5
mc_open
read -r x y <<<"$(desk_corner 1)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
wait_until 4 bash -c "[ \$(ndesk) = 4 ]"
eq "the desktop is gone"                   "$(ndesk)" 4
eq "the Space moved up with it"            "$(desk_of "$F")" 1
eq "and now comes from the desktop before" "$(origin_of "$F")" 0
eq "later windows moved down one"          "$(desk_of "$B")" 3
eq "the first desktop's window stayed"     "$(desk_of "$A")" 0
eq "the app is still full screen"          "$(is_full "$F" && echo yes)" yes
mc --close; sleep 0.3
wmctrl -i -r "$F" -b remove,fullscreen
wait_until 4 bash -c "[ \$(ndesk) = 3 ]"; sleep 0.5
eq "leaving full screen returns to desktop 0" "$(desk_of "$F")" 0
stop_fullscreen

t_begin "mission-control: the first desktop can be removed even with a Space after it"
reset_desktops; start_fullscreen
A=$(open_win mc-a); F=$(open_win mc-full); B=$(open_win mc-b)
wmctrl -i -r "$A" -t 0; wmctrl -i -r "$F" -t 0; wmctrl -i -r "$B" -t 1; go 0; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 1 ]"; sleep 0.5; go 0
eq "five desktops: 0, its Space 1, 2, 3, 4" "$(ndesk)" 5
eq "B (on the old desktop 2... was 1) is on 2" "$(desk_of "$B")" 2
mc_open
read -r x y <<<"$(desk_corner 0)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
wait_until 4 bash -c "[ \$(ndesk) = 4 ]"
eq "the desktop is gone"                   "$(ndesk)" 4
eq "its window went to the next desktop"   "$(desk_of "$A")" 0
eq "which is now the first"                "$(desk_of "$B")" 0
eq "the Space now follows that desktop"    "$(desk_of "$F")" 1
eq "and comes from it"                     "$(origin_of "$F")" 0
mc --close; sleep 0.3
wmctrl -i -r "$F" -b remove,fullscreen
wait_until 4 bash -c "[ \$(ndesk) = 3 ]"; sleep 0.5
eq "leaving full screen returns to desktop 0" "$(desk_of "$F")" 0
stop_fullscreen

t_begin "mission-control: the last ordinary desktop can't be removed"
reset_desktops; set_desktops 1; start_fullscreen
F=$(open_win mc-full); go 0; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(ndesk) = 2 ]"; sleep 0.5; go 0
mc_open
read -r x y <<<"$(desk_corner 0)"; xdotool mousemove $((x + 20)) $((y + 20)); sleep 0.2; click_at "$x" "$y"
sleep 0.5
eq "still two desktops (it and its Space)" "$(ndesk)" 2
wmctrl -i -r "$F" -b remove,fullscreen; sleep 1.2; stop_fullscreen

t_begin "mission-control: a Space can't be dragged along the bar"
reset_desktops; start_fullscreen
F=$(open_win mc-full); wmctrl -i -r "$F" -t 1; go 1; wmctrl -i -a "$F"; sleep 0.2
wmctrl -i -r "$F" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 2 ]"; sleep 0.5; go 0
mc_open
read -r x1 y1 <<<"$(desk_center 2)"; read -r x2 y2 <<<"$(desk_center 4)"
drag "$x1" "$y1" $((x2 + 30)) "$y2"
eq "it stayed where it is"                 "$(desk_of "$F")" 2
mc --close; sleep 0.3
wmctrl -i -r "$F" -b remove,fullscreen; sleep 1.2; stop_fullscreen

t_begin "mission-control: a wallpaper that is not a good JPEG doesn't stop it"
reset_desktops
echo "this is not an image" > "$LIVE_TMP/bad.jpg"
printf '\xff\xd8\xff\xe0 truncated' > "$LIVE_TMP/cut.jpg"
for f in bad cut; do
    xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image -n -t string -s "$LIVE_TMP/$f.jpg"
    mc_open
    check "opens with a $f wallpaper"      test -f "$MISSION_CONTROL_LAYOUT"
    check "and the program is still running" kill -0 "$MC_PID"
    mc --close; sleep 0.3
done
xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitor0/workspace0/last-image -r

t_begin "mission-control: a minimized window is shown, dimmed, and a click brings it back"
reset_desktops
A=$(open_win mc-a); B=$(open_win mc-b)
xdotool windowminimize "$B"; sleep 0.6
check "it is minimized"                    bash -c "xprop -id $B _NET_WM_STATE | grep -q HIDDEN"
mc_open
eq "both windows are listed"               "$(lay | grep -c '^item ')" 2
eq "the minimized one is marked"           "$(lay | awk -v w="$(hex "$B")" '$1=="item" && $2==w {print $7}')" min
eq "the other one is not"                  "$(lay | awk -v w="$(hex "$A")" '$1=="item" && $2==w {print $7}')" ""
read -r x y <<<"$(item_center "$(hex "$B")")"; click_at "$x" "$y"
wait_until 3 bash -c "! xprop -id $B _NET_WM_STATE | grep -q HIDDEN"
check "clicking it brings it back"         bash -c "! xprop -id $B _NET_WM_STATE | grep -q HIDDEN"
eq "and it is the active window"           "$(active)" "$(hex "$B")"

t_begin "mission-control: a minimized window keeps its last look (needs a compositor: LIVE_COMPOSITOR=1)"
if [[ -n "${LIVE_COMPOSITOR:-}" ]]; then
    reset_desktops
    A=$(open_win mc-a); B=$(open_win mc-b)
    sleep 2                                              # let the daemon note the windows' images
    xdotool windowminimize "$B"; sleep 0.6
    mc_open
    wait_until 3 bash -c "grep -q '^item $(hex "$B") .* min img' '$MISSION_CONTROL_LAYOUT'"
    eq "the minimized window has its last look" "$(lay | awk -v w="$(hex "$B")" '$1=="item" && $2==w {print $7, $8}')" "min img"
    mc --close; sleep 0.3
else
    echo "  (skipped: no compositor in the test display)"
fi

t_begin "mission-control: the show-desktop corner does nothing behind it"
reset_desktops
A=$(open_win mc-a); wmctrl -i -a "$A"; sleep 0.3
mc_open
"$BIN/show-desktop"; sleep 0.6
mc --close; sleep 0.3
check "the window was not hidden"          bash -c "! xprop -id $A _NET_WM_STATE | grep -q HIDDEN"

t_begin "mission-control: windows and desktops changing while it is open show up"
reset_desktops
A=$(open_win mc-a); B=$(open_win mc-b)
mc_open
eq "two windows"                           "$(lay | grep -c '^item ')" 2
wmctrl -i -c "$B"
wait_until 4 bash -c "[ \$(grep -c '^item ' '$MISSION_CONTROL_LAYOUT') = 1 ]"
eq "one window after one closes"           "$(lay | grep -c '^item ')" 1
set_desktops 3
wait_until 4 bash -c "[ \$(grep -c '^desk ' '$MISSION_CONTROL_LAYOUT') = 3 ]"
eq "three desktops after the count changes" "$(lay | grep -c '^desk ')" 3
mc --close; sleep 0.3
set_desktops 4

t_begin "mission-control: at 16 desktops there is no +"
reset_desktops; set_desktops 16
mc_open
check "no +"                               bash -c "! grep -q '^plus ' '$MISSION_CONTROL_LAYOUT'"
mc --close; sleep 0.3
set_desktops 4

t_begin "mission-control: a desktop keeps its picture"
reset_desktops
A=$(open_win mc-a); wmctrl -i -r "$A" -t 1; go 1; sleep 1.6   # arrive, let it settle: snapshot
go 0; sleep 0.3
mc_open
eq "desktop 2 has a picture"               "$(lay | awk '$1=="desk" && $2==1 {print $7}')" 1
eq "empty desktop 3 shows the wallpaper"   "$(lay | awk '$1=="desk" && $2==2 {print $7}')" 0
mc --close; sleep 0.3
kill "$MC_PID" 2>/dev/null
unset MISSION_CONTROL_LAYOUT
