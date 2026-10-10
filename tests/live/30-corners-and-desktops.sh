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
