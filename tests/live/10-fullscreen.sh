# fullscreen: Spaces, the green button, the top and bottom edges, show-desktop (sourced by live.sh)

t_begin "fullscreen: a Space right after the window's own desktop"
reset_desktops; start_fullscreen
A=$(open_win fs-a); B=$(open_win fs-b)
wmctrl -i -r "$A" -t 1; wmctrl -i -r "$B" -t 2; go 1; wmctrl -i -a "$A"; sleep 0.3
wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(desk_of $A) = 2 ]"
eq "one more desktop"                     "$(ndesk)" 5
eq "the window is on the new Space (2)"   "$(desk_of "$A")" 2
eq "and we're there"                      "$(curdesk)" 2
eq "it remembers its own desktop"         "$(origin_of "$A")" 1
eq "the next desktop's window moved up"   "$(desk_of "$B")" 3

t_begin "fullscreen: leaving it goes back and removes the Space"
wmctrl -i -r "$A" -b remove,fullscreen
wait_until 3 bash -c "[ \$(ndesk) = 4 ]"
eq "back to 4 desktops"                   "$(ndesk)" 4
eq "the window is back on desktop 1"      "$(desk_of "$A")" 1
eq "and so are we"                        "$(curdesk)" 1
eq "the other window moved back down"     "$(desk_of "$B")" 2
eq "nothing remembered any more"          "$(origin_of "$A")" ""

t_begin "fullscreen: closing a full-screen window removes its Space"
wmctrl -i -a "$A"; wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(ndesk) = 5 ]"
close_win "$A"
wait_until 3 bash -c "[ \$(ndesk) = 4 ]"
eq "back to 4 desktops"                   "$(ndesk)" 4
eq "back on the desktop it came from"     "$(curdesk)" 1
eq "the other window moved back down"     "$(desk_of "$B")" 2

t_begin "fullscreen: a new window opened from a Space goes to the app's desktop"
reset_desktops; start_fullscreen
A=$(open_win fs-a); wmctrl -i -r "$A" -t 2; go 2; wmctrl -i -a "$A"; sleep 0.2
wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 3 ]"
C=$(open_win fs-new)
wait_until 3 bash -c "[ \$(desk_of $C) = 2 ]"
eq "the new window went to desktop 2"     "$(desk_of "$C")" 2
eq "and we slid there"                    "$(curdesk)" 2
eq "the full-screen app stays on its Space" "$(desk_of "$A")" 3

t_begin "fullscreen: the app's own dialog stays on top of it"
reset_desktops; start_fullscreen
A=$(open_win fs-app --child fs-dialog 4); wmctrl -i -r "$A" -t 1; go 1; wmctrl -i -a "$A"; sleep 0.2
wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 2 ]"
wait_until 5 bash -c "xdotool search --name '^fs-dialog$' >/dev/null"; sleep 0.5
D=$(win_id fs-dialog)
eq "the dialog opened on the app's Space" "$(desk_of "$D")" 2
eq "we stayed there"                      "$(curdesk)" 2

t_begin "fullscreen: a restart of the program doesn't strand a window"
reset_desktops; start_fullscreen
A=$(open_win fs-a); wmctrl -i -r "$A" -t 1; go 1; wmctrl -i -a "$A"; sleep 0.2
wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(ndesk) = 5 ]"
start_fullscreen
wmctrl -i -r "$A" -b remove,fullscreen
wait_until 3 bash -c "[ \$(ndesk) = 4 ]"
eq "back on its own desktop"              "$(desk_of "$A")" 1
eq "the Space is gone"                    "$(ndesk)" 4

t_begin "fullscreen: at most 16 Spaces, as on macOS"
reset_desktops; start_fullscreen; set_desktops 16
A=$(open_win fs-a); wmctrl -i -r "$A" -t 3; go 3; wmctrl -i -a "$A"; sleep 0.2
wmctrl -i -r "$A" -b add,fullscreen; sleep 1
check "the window is full screen"         is_full "$A"
eq "no 17th desktop"                      "$(ndesk)" 16
eq "it stays on its desktop"              "$(desk_of "$A")" 3

t_begin "fullscreen: the green button (a click in the button area, then maximize) goes full screen"
reset_desktops; start_fullscreen
A=$(open_win fs-a); wmctrl -i -a "$A"; sleep 0.3
eval "$(xwininfo -id "$A" | awk '/Absolute upper-left X/{print "X=" $4} /Absolute upper-left Y/{print "Y=" $4}')"
top=$(xprop -id "$A" _NET_FRAME_EXTENTS | awk -F', ' '{print $3}')
xdotool mousemove $((X + 100)) $((Y - top / 2)) click 1     # in the button area, not on a button
wmctrl -i -r "$A" -b add,maximized_vert,maximized_horz       # what the maximize button does
wait_until 3 is_full "$A"
check "full screen instead of maximized"  is_full "$A"
check "not left maximized" bash -c "! xprop -id $A _NET_WM_STATE | grep -q MAXIMIZED"
eq "on its own Space"                     "$(desk_of "$A")" 1

t_begin "fullscreen: maximizing without that click stays a plain maximize"
B=$(open_win fs-b); wmctrl -i -r "$B" -t 0; go 0; wmctrl -i -a "$B"; sleep 1.2
wmctrl -i -r "$B" -b add,maximized_vert,maximized_horz; sleep 0.8
check "maximized"                         bash -c "xprop -id $B _NET_WM_STATE | grep -q MAXIMIZED_VERT"
check "not full screen"                   bash -c "! xprop -id $B _NET_WM_STATE | grep -q FULLSCREEN"

t_begin "fullscreen: the top edge brings the title bar (and menu bar); green leaves full screen"
reset_desktops; start_fullscreen
A=$(open_win fs-a); wmctrl -i -a "$A"; wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 1 ]"; sleep 0.3
xdotool mousemove 700 400; sleep 0.2; xdotool mousemove 700 0
wait_until 2 mapped "fullscreen title bar"
check "the title bar is shown"            mapped "fullscreen title bar"
check "it has the focus (so the panel shows above the app)" bash -c "[ \$(active) != $(hex "$A") ]"
xdotool mousemove 700 400
wait_until 2 bash -c '! mapped "fullscreen title bar"'; sleep 0.3
check "moving away hides it"              bash -c '! mapped "fullscreen title bar"'
eq "the app has the focus back"           "$(active)" "$(hex "$A")"
xdotool mousemove 700 0; wait_until 2 mapped "fullscreen title bar"
xdotool mousemove 60 15 click 1
wait_until 3 bash -c "! is_full $A"
check "green leaves full screen"          bash -c "! is_full $A"
eq "back on its desktop"                  "$(desk_of "$A")" 0

t_begin "fullscreen: the bottom edge brings up the Dock"
wmctrl -i -a "$A"; wmctrl -i -r "$A" -b add,fullscreen
wait_until 3 bash -c "[ \$(curdesk) = 1 ]"; sleep 0.3
xdotool mousemove 700 400; sleep 0.2; xdotool mousemove 700 899
wait_until 2 mapped "fullscreen dock helper"
check "the app gives up the focus (the dock shows above it)" bash -c "[ \$(active) != $(hex "$A") ]"
xdotool mousemove 700 300; sleep 0.8
eq "moving away gives it back"            "$(active)" "$(hex "$A")"

t_begin "show-desktop: nothing in a full-screen app, a toggle elsewhere"
showing() { xprop -root _NET_SHOWING_DESKTOP | awk '/= /{print $3; exit} END{if (!NR || $0 ~ /not found/) print 0}' | head -1; }
"$BIN/show-desktop"; sleep 0.5
eq "full screen: the desktop is not shown" "$(showing)" 0
wmctrl -i -r "$A" -b remove,fullscreen; sleep 1; wmctrl -i -a "$A"; sleep 0.3
"$BIN/show-desktop"; sleep 0.5
eq "otherwise it shows the desktop"       "$(showing)" 1
"$BIN/show-desktop"; sleep 0.5
eq "and again brings the windows back"    "$(showing)" 0
stop_fullscreen
