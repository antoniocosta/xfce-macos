#!/usr/bin/env bash
# The change record and --restore (lib/common.sh, lib/restore.sh), in a temporary home with its own
# D-Bus session, so xfconf and dconf are real but not yours. sudo, systemctl and apt-get are stubs
# that only write a log; nothing here touches the real system or settings.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${RESTORE_INSIDE:-}" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp"/{home,config,state,stub,run}; chmod 700 "$tmp/run"
    cat > "$tmp/stub/sudo" <<'S'
#!/bin/sh
echo "sudo $*" >> "$STUB_LOG"
[ "$1" = -v ] && exit 0
exec "$@"
S
    cat > "$tmp/stub/systemctl" <<'S'
#!/bin/sh
echo "systemctl $*" >> "$STUB_LOG"
for a in "$@"; do last=$a; done
case " $* " in
    *" is-enabled "*) cat "$STUB_DIR/enabled.$last" 2>/dev/null || echo enabled ;;
    *" is-active "*)  cat "$STUB_DIR/active.$last" 2>/dev/null || echo active ;;
    *" list-unit-files "*) echo "$last enabled" ;;
esac
exit 0
S
    printf '#!/bin/sh\necho "apt-get $*" >> "$STUB_LOG"\n' > "$tmp/stub/apt-get"
    printf '#!/bin/sh\nexit 1\n' > "$tmp/stub/dpkg-query"
    chmod +x "$tmp"/stub/*
    exec env -i PATH="$tmp/stub:/usr/local/bin:/usr/bin:/bin" HOME="$tmp/home" \
        XDG_CONFIG_HOME="$tmp/config" XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" \
        STUB_LOG="$tmp/stub.log" STUB_DIR="$tmp/stub" LU_NO_REFRESH=1 RESTORE_INSIDE=1 RESTORE_TMP="$tmp" \
        TERM="${TERM:-dumb}" dbus-run-session -- bash "$0" "$@"
fi

. "$HERE/lib.sh"
T=$RESTORE_TMP
. "$ROOT/lib/common.sh"
. "$ROOT/lib/restore.sh"
STATE="$(state_dir)"
restore() { lu_restore "$@" 2>&1; }
tree_sum() { (cd "$T" && find home config -type f -not -path 'config/dconf/*' -not -path 'config/xfce4/*' -print0 | sort -z | xargs -0 sha1sum; find home -type d) | sha1sum; }

t_begin "upsert_block: record, restore, no trace"
f="$HOME/file.css"; printf 'body { color: red; }\n' > "$f"; orig="$(sha1sum < "$f")"
upsert_block "$f" "/* >>> t */" "/* <<< t */" "a { b: c; }" >/dev/null
upsert_block "$HOME/.config/new.css" "/* >>> t */" "/* <<< t */" "a { b: c; }" >/dev/null
upsert_block "$f" "/* >>> t */" "/* <<< t */" "a { b: d; }" >/dev/null
eq "one record per file, none for the re-run" "$(grep -c '^block' "$STATE/changes")" 2
restore run --yes >/dev/null
eq "an existing file is back byte for byte" "$(sha1sum < "$f")" "$orig"
check "a file we created is deleted"        test ! -e "$HOME/.config/new.css"
check "the record is gone after a restore"  test ! -e "$STATE"

t_begin "upsert_block: a block in the middle of a file (Toshy style)"
printf 'one\n\n/* >>> t */\nx\n/* <<< t */\n\nEND\n' > "$f"
rec block "$f" "/* >>> t */" "/* <<< t */" existed
restore run --yes >/dev/null
eq "the rest is kept" "$(tr '\n' '|' < "$f")" "one||END|"

t_begin "install_file / install_bin: created vs replaced"
printf 'path=@HOME@/x\n' > "$T/src"; printf '#!/bin/sh\n' > "$T/prog"
install_file "$T/src" "$HOME/cfg/new" >/dev/null
echo "mine" > "$HOME/cfg/old"; mode_before="$(stat -c %a "$HOME/cfg/old")"
install_file "$T/src" "$HOME/cfg/old" >/dev/null
install_file "$T/src" "$HOME/cfg/old" >/dev/null
install_bin "$T/prog"; install_bin "$T/prog"
sum1="$(sha1sum < "$STATE/changes")"
install_file "$T/src" "$HOME/cfg/new" >/dev/null; install_bin "$T/prog"
eq "a re-run adds nothing to the record" "$(sha1sum < "$STATE/changes")" "$sum1"
restore dry >/dev/null
check "--dry-run leaves everything" test -f "$HOME/cfg/new" -a -x "$BIN/prog" -a -f "$STATE/changes"
restore run --yes >/dev/null
check "a created file is removed"     test ! -e "$HOME/cfg/new"
eq "a replaced file is the original again" "$(cat "$HOME/cfg/old")" mine
eq "its mode is kept" "$(stat -c %a "$HOME/cfg/old")" "$mode_before"
check "the .bak copy install_file made is tidied" bash -c "! ls '$HOME'/cfg/old.bak.* 2>/dev/null"
check "the installed program is removed" test ! -e "$BIN/prog"
check "empty folders we made are removed" test ! -d "$HOME/cfg" -o -f "$HOME/cfg/old"

t_begin "a file installed by an earlier version (no record) is still removed"
install_file "$T/src" "$HOME/cfg/legacy" >/dev/null; rm -rf "$STATE"
install_file "$T/src" "$HOME/cfg/legacy" >/dev/null
restore run --yes >/dev/null
check "identical content counts as ours" test ! -e "$HOME/cfg/legacy"

t_begin "track_new: only what a command newly puts in a folder"
mkdir -p "$HOME/themes/keep"
track_new "$HOME/themes" mkdir "$HOME/themes/added"
restore run --yes >/dev/null
check "the new entry is removed, the old one kept" test ! -e "$HOME/themes/added" -a -d "$HOME/themes/keep"

t_begin "xfconf: absent vs present, scalars and arrays"
xfconf-query -c t -p /keep -n -t int -s 7
xfconf-query -c t -p /arr -n --force-array -t string -s a -t string -s "b c"
xfset t /keep int 9; xfset t /fresh string "hello world"; xfset t /keep int 9
xfset_strings t /arr one two three; xfset_strings t /newarr x y
eq "values are set" "$(xfconf-query -c t -p /keep):$(xfconf-query -c t -p /fresh)" "9:hello world"
eq "a re-run records nothing new" "$(grep -c '^xf' "$STATE/changes")" 4
out="$(restore list)"
[[ "$out" == *"xfconf t /fresh"* ]] && pass "--list-changes lists them" || fail "--list-changes lists them"
restore run --yes >/dev/null
eq "a present value is back"     "$(xfconf-query -c t -p /keep)" 7
eq "an array is back"            "$(xfconf-query -c t -p /arr | tail -n +3 | tr '\n' '|')" "a|b c|"
check "an absent one is removed" bash -c '! xfconf-query -c t -p /fresh >/dev/null 2>&1'
check "an absent array is removed" bash -c '! xfconf-query -c t -p /newarr >/dev/null 2>&1'

t_begin "gsettings / dconf: user value vs default"
if gsettings list-keys org.gnome.desktop.interface >/dev/null 2>&1; then
    gsettings set org.gnome.desktop.interface font-name 'Mine 9'
    gset org.gnome.desktop.interface font-name 'Inter 10'
    gset org.gnome.desktop.interface cursor-theme 'macOS'
    gset org.gnome.desktop.interface cursor-theme 'macOS'
    printf '[/]\ndock-items=['"'a.dockitem'"']\n' | dconf_load /net/test/dock1/
    eq "set" "$(gsettings get org.gnome.desktop.interface font-name)" "'Inter 10'"
    restore run --yes >/dev/null
    eq "the user's value is back"        "$(gsettings get org.gnome.desktop.interface font-name)" "'Mine 9'"
    eq "an unset key is back to default" "$(dconf read /org/gnome/desktop/interface/cursor-theme)" ""
    eq "a loaded tree is gone"           "$(dconf dump /net/test/dock1/)" ""
else echo "  (no gsettings schemas here: skipped)"; fi

t_begin "programs the installer started are stopped by exact name"
cp /bin/sleep "$T/lu-test-proc-1"; "$T/lu-test-proc-1" 300 >/dev/null 2>&1 & sp=$!
track_proc lu-test-proc-1
restore run --yes >/dev/null
sleep 0.2; check "the process is stopped" bash -c "! kill -0 $sp 2>/dev/null"
wait "$sp" 2>/dev/null

t_begin "system parts (sudo) and packages, with stubs"
echo "orig" > "$T/etc-file"; echo enabled > "$T/stub/enabled.svc.service"; echo inactive > "$T/stub/active.svc.service"
track_sys "$T/etc-file"; echo changed > "$T/etc-file"
track_sys "$T/etc-new"; echo x > "$T/etc-new"
unit_record system svc.service; echo masked > "$T/stub/enabled.svc.service"
rec pkg newpkg; rec pkgrm oldpkg
note_change "something that cannot be undone"
out="$(restore list)"
echo "$out" | grep -q 'cannot be undone' && pass "notes are listed" || fail "notes are listed"
: > "$T/stub.log"
restore run --yes >/dev/null
eq "system file put back" "$(cat "$T/etc-file")" orig
check "system file we created removed" test ! -e "$T/etc-new"
check "the unit is enabled again, not started" grep -q 'enable svc.service' "$T/stub.log"
check "sudo was asked once up front" test "$(grep -c '^sudo -v' "$T/stub.log")" = 1
check "packages are left alone without --packages" bash -c "! grep -q apt-get '$T/stub.log'"
track_file "$T/f"; echo mine > "$T/f"; rec pkg newpkg; rec pkgrm oldpkg
: > "$T/stub.log"; restore run --packages --yes >/dev/null
check "--packages removes the new and reinstalls the removed" bash -c "grep -q 'apt-get remove -y newpkg' '$T/stub.log' && grep -q 'apt-get install -y oldpkg' '$T/stub.log'"

t_begin "restore twice, and with parts already gone"
install_file "$T/src" "$HOME/cfg/a" >/dev/null; rm -f "$HOME/cfg/a"
xfset t /gone string v; xfconf-query -c t -p /gone -r
out="$(restore run --yes)"; rc=$?
eq "first restore works with things missing" "$rc" 0
out="$(restore run --yes)"; rc=$?
eq "a second restore is a no-op" "$rc:$(grep -c 'Nothing recorded' <<<"$out")" "0:1"
out="$(restore run --yes)"
check "--list-changes with nothing recorded" test -n "$(restore list)"

t_begin "without --yes it asks, and a no changes nothing"
install_file "$T/src" "$HOME/cfg/ask" >/dev/null
echo n | lu_restore run >/dev/null 2>&1
check "answer n: still there, record kept" test -f "$HOME/cfg/ask" -a -f "$STATE/changes"
restore run --yes >/dev/null
check "--yes: removed" test ! -e "$HOME/cfg/ask"

t_begin "the command line: macos-xfce/install.sh --list-changes / --restore"
INST="$ROOT/macos-xfce/install.sh"
install_file "$T/src" "$HOME/cfg/cli" >/dev/null
sum0="$(tree_sum)"
out="$("$INST" --list-changes 2>&1)"
[[ "$out" == *"remove $HOME/cfg/cli"* ]] && pass "--list-changes shows what was installed" || fail "--list-changes shows what was installed"
"$INST" --restore --dry-run >/dev/null 2>&1
eq "--restore --dry-run changes nothing" "$(tree_sum)" "$sum0"
"$INST" --restore --yes >/dev/null 2>&1
check "--restore --yes undoes it" test ! -e "$HOME/cfg/cli" -a ! -e "$STATE"
"$INST" --restore --yes >/dev/null 2>&1; eq "a second --restore exits 0" "$?" 0
"$INST" --dry-run >/dev/null 2>&1; eq "--dry-run alone is refused" "$?" 1
check "no program is left in ~/.local/bin" test -z "$(ls -A "$BIN" 2>/dev/null)"

t_summary
