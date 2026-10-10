#!/usr/bin/env bash
# The installers' helpers (lib/common.sh), in a temporary home.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME"
. "$ROOT/lib/common.sh"

t_begin "upsert_block: adds once, replaces in place, never duplicates"
f="$HOME/file.css"
printf 'body { color: red; }\n' > "$f"
eq "first run reports a change"   "$(upsert_block "$f" "/* >>> t */" "/* <<< t */" "a { b: c; }")" changed
eq "second run changes nothing"    "$(upsert_block "$f" "/* >>> t */" "/* <<< t */" "a { b: c; }")" ""
eq "the block is there once"       "$(grep -c '>>> t' "$f")" 1
upsert_block "$f" "/* >>> t */" "/* <<< t */" "a { b: d; }" >/dev/null
eq "a new body replaces the old"   "$(grep -c 'b: d' "$f"):$(grep -c 'b: c' "$f")" "1:0"
eq "the rest of the file is kept"  "$(head -1 "$f")" "body { color: red; }"
upsert_block "$HOME/new/dir/file" "# >>> x" "# <<< x" "y" >/dev/null
check "creates missing files and folders" test -f "$HOME/new/dir/file"

t_begin "install_file: fills in @HOME@, keeps a backup of a different file"
printf 'path=@HOME@/x\n' > "$tmp/src"
eq "first install reports a change" "$(install_file "$tmp/src" "$HOME/cfg/a")" changed
eq "@HOME@ is filled in"            "$(cat "$HOME/cfg/a")" "path=$HOME/x"
eq "same content: no change"        "$(install_file "$tmp/src" "$HOME/cfg/a")" ""
echo "mine" > "$HOME/cfg/a"
install_file "$tmp/src" "$HOME/cfg/a" >/dev/null
check "a different file is backed up first" bash -c "grep -q mine '$HOME'/cfg/a.bak.*"
eq "installed files are readable by all" "$(stat -c %a "$HOME/cfg/a")" 644

t_begin "packages_of: names only, comments ignored"
mkdir -p "$tmp/pk"; printf 'one two   # a comment\n# only a comment\nthree\n' > "$tmp/pk/packages"
eq "parsed list" "$(packages_of "$tmp/pk" | tr '\n' ' ')" "one two three "
eq "no packages file: nothing" "$(packages_of "$tmp/none" | wc -l)" 0

t_begin "autostart_entry"
autostart_entry "Hot Corners" "/x/hot-corners"
check "file named after the entry" grep -q '^Exec=/x/hot-corners$' "$HOME/.config/autostart/hot-corners.desktop"

t_begin "vpntray: parsers and the provider adapter (against a fake CLI)"
check "unit tests pass" python3 "$ROOT/extras/vpntray/test_vpntray.py"

t_summary
