# idle-watch: says "idle" when the screen's power-save time has passed, "active" at the next movement,
# and sleeps in between (sourced by live.sh)

t_begin "idle-watch: idle and active, driven by the X server (no polling)"
IDLE_OUT="$LIVE_TMP/idle.out"; : > "$IDLE_OUT"
xdotool mousemove 200 200
IDLE_WATCH_SECONDS=2 "$BIN/idle-watch" > "$IDLE_OUT" 2>&1 & IW=$!
sleep 0.8
eq "says nothing while you are active"     "$(cat "$IDLE_OUT")" ""
wait_until 5 grep -q idle "$IDLE_OUT"
eq "idle once the time has passed"         "$(sed -n 1p "$IDLE_OUT")" idle
xdotool mousemove 300 300
wait_until 3 grep -q active "$IDLE_OUT"
eq "active at the next movement"           "$(sed -n 2p "$IDLE_OUT")" active
wait_until 6 bash -c "[ \$(grep -c idle '$IDLE_OUT') = 2 ]"
eq "idle again after the next quiet spell" "$(sed -n 3p "$IDLE_OUT")" idle
xdotool key shift
wait_until 3 bash -c "[ \$(grep -c active '$IDLE_OUT') = 2 ]"
eq "and a key press brings it back"        "$(sed -n 4p "$IDLE_OUT")" active
# it sleeps: no CPU used while waiting
c0=$(awk '{print $14+$15}' /proc/$IW/stat); sleep 3; c1=$(awk '{print $14+$15}' /proc/$IW/stat)
check "no CPU while waiting (event driven)" bash -c "[ $((c1 - c0)) -le 1 ]"
kill "$IW" 2>/dev/null

t_begin "idle-watch: the screen saver's time counts too (a screen locker locks then)"
IDLE_OUT="$LIVE_TMP/idle2.out"; : > "$IDLE_OUT"
xset s 8 8
xdotool mousemove 210 210
"$BIN/idle-watch" > "$IDLE_OUT" 2>&1 & IW=$!
sleep 4
eq "nothing yet, well before the time"     "$(cat "$IDLE_OUT")" ""
wait_until 8 grep -q idle "$IDLE_OUT"
eq "idle when the screen saver's time has passed" "$(sed -n 1p "$IDLE_OUT")" idle
kill "$IW" 2>/dev/null
xset s default
