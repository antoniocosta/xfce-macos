# hotcorner and desktop-switch (sourced by live.sh)

t_begin "hotcorner: a corner fires after resting there, not while a button is held"
reset_desktops
"$BIN/hotcorner" -d 100 tr "touch $LIVE_TMP/tr" br "touch $LIVE_TMP/br" >/dev/null 2>&1 &
HC=$!; sleep 0.4
xdotool mousemove 700 400; sleep 0.3; xdotool mousemove 1439 0
wait_until 2 test -f "$LIVE_TMP/tr"
check "top right fired"                     test -f "$LIVE_TMP/tr"
check "bottom right did not"                bash -c "! test -f '$LIVE_TMP/br'"
xdotool mousemove 700 400 mousedown 1; sleep 0.2; xdotool mousemove 1439 899; sleep 0.8
check "not while dragging"                  bash -c "! test -f '$LIVE_TMP/br'"
xdotool mouseup 1; sleep 0.6
check "fires once the button is up"         test -f "$LIVE_TMP/br"
rm -f "$LIVE_TMP/tr"; xdotool mousemove 1439 0; sleep 0.05; xdotool mousemove 700 400; sleep 0.3
check "a quick pass doesn't fire"           bash -c "! test -f '$LIVE_TMP/tr'"
kill "$HC" 2>/dev/null

t_begin "desktop-switch: next and previous, never wrapping around"
reset_desktops; go 0
"$BIN/desktop-switch" prev; sleep 0.3
eq "prev on the first desktop stays"        "$(curdesk)" 0
"$BIN/desktop-switch" next; sleep 0.3
eq "next goes to desktop 2"                 "$(curdesk)" 1
go 3; "$BIN/desktop-switch" next; sleep 0.3
eq "next on the last desktop stays"         "$(curdesk)" 3
"$BIN/desktop-switch" prev; sleep 0.3
eq "prev goes back one"                     "$(curdesk)" 2

t_begin "hotcorner: a finger resting in the corner doesn't fire it again, moving away and back does"
reset_desktops
rm -f "$LIVE_TMP/tr"
"$BIN/hotcorner" -d 100 tr "echo x >> $LIVE_TMP/tr" >/dev/null 2>&1 &
HC=$!; sleep 0.4
xdotool mousemove 700 400; sleep 0.3; xdotool mousemove 1439 0
wait_until 2 test -f "$LIVE_TMP/tr"
for i in 1 2 3 4; do xdotool mousemove 1436 3; sleep 0.15; xdotool mousemove 1439 0; sleep 0.25; done
eq "fired once, however much it wobbles"     "$(wc -l < "$LIVE_TMP/tr")" 1
xdotool mousemove 1300 200; sleep 0.3; xdotool mousemove 1439 0; sleep 0.6
eq "and again after leaving and coming back" "$(wc -l < "$LIVE_TMP/tr")" 2
kill "$HC" 2>/dev/null

t_begin "show-desktop: its windows come back even after their desktop was renumbered"
reset_desktops
A=$(open_win sd-a); B=$(open_win sd-b)
wmctrl -i -r "$A" -t 1; wmctrl -i -r "$B" -t 1; go 1; wmctrl -i -a "$B"; sleep 0.3
"$BIN/show-desktop"; sleep 0.8
check "hidden"                               bash -c "xprop -id $A _NET_WM_STATE | grep -q HIDDEN && xprop -id $B _NET_WM_STATE | grep -q HIDDEN"
wmctrl -i -r "$A" -t 2; wmctrl -i -r "$B" -t 2; sleep 0.3; go 2   # what a renumbering does: the windows are on another number now
"$BIN/show-desktop"; sleep 0.8
check "back"                                 bash -c "! xprop -id $A _NET_WM_STATE | grep -q HIDDEN && ! xprop -id $B _NET_WM_STATE | grep -q HIDDEN"
eq "the window that had the focus has it again" "$(active)" "$(hex "$B")"
check "the marks are gone"                   bash -c "! xprop -id $A _MACOS_SHOW_DESKTOP | grep -q '= '"

t_begin "show-desktop: --hide only hides, --restore only brings back"
reset_desktops
A=$(open_win sd-a); wmctrl -i -a "$A"; sleep 0.3
"$BIN/show-desktop" --restore; sleep 0.4
check "--restore with nothing hidden changes nothing" bash -c "! xprop -id $A _NET_WM_STATE | grep -q HIDDEN"
"$BIN/show-desktop" --hide; sleep 0.8
check "--hide hides"                         bash -c "xprop -id $A _NET_WM_STATE | grep -q HIDDEN"
"$BIN/show-desktop" --hide; sleep 0.5
check "--hide again doesn't bring it back"   bash -c "xprop -id $A _NET_WM_STATE | grep -q HIDDEN"
"$BIN/show-desktop" --restore; sleep 0.8
check "--restore brings it back"             bash -c "! xprop -id $A _NET_WM_STATE | grep -q HIDDEN"

t_begin "desktop-switch: quick repeats each count, and no slide marks are left behind"
reset_desktops
A=$(open_win ds-a); go 0
"$BIN/desktop-switch" next; "$BIN/desktop-switch" next; "$BIN/desktop-switch" next
wait_until 3 bash -c "[ \$(curdesk) = 3 ]"
eq "three swipes went three desktops"        "$(curdesk)" 3
sleep 1.2
check "the marks are cleared"                bash -c "! xprop -id $A _MAC_SLIDE | grep -q '= '"
