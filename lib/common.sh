# shellcheck shell=bash
# Shared helpers for the install scripts (sourced, not run).
# Every helper checks before it changes anything, so the installers are safe to re-run.

BIN="$HOME/.local/bin"
SRC="$HOME/.local/src"
AUTOSTART="$HOME/.config/autostart"
TAG="xfce-macos"            # marks the blocks we add to files we share with other tools
export PATH="$BIN:$PATH"

info()    { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()      { printf '\033[1;32m[OK]\033[0m   %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die()     { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }
section() { printf '\n\033[1;35m==================== %s ====================\033[0m\n' "$*"; }

require_xfce() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == *XFCE* ]] || die "Run this inside an Xfce desktop session."
    [[ "${XDG_SESSION_TYPE:-x11}" == x11 ]] || die "This needs Xfce on X11."
}

need() {  # need COMMAND PACKAGE: stop with an apt hint when a command is missing
    command -v "$1" >/dev/null || die "'$1' is missing: sudo apt install $2"
}

# ---- change record (for --restore) -------------------------------------------------------
# The first time an installer step changes something, it records how to put it back, in
# ${XDG_STATE_HOME:-~/.local/state}/xfce-macos/ (file "changes" plus "backup/"). Each thing is
# recorded once only, so a restore returns to what the machine was before the FIRST install; a
# re-run adds nothing. lib/restore.sh reads the record. Fields are separated by US (0x1f).

state_dir() { echo "${XDG_STATE_HOME:-$HOME/.local/state}/xfce-macos"; }

rec() {  # rec KIND FIELD...: append one record
    local IFS=$'\x1f' d; d="$(state_dir)"
    mkdir -p "$d/backup"
    printf '%s\n' "$*" >> "$d/changes"
}

rec_has() {  # rec_has KIND FIELD...: is there a record starting with these fields?
    local IFS=$'\x1f' key
    key="$*"$'\x1f'
    K="$key" awk 'index($0, ENVIRON["K"]) == 1 {f = 1} END {exit !f}' "$(state_dir)/changes" 2>/dev/null
}

rec_once() { rec_has "$1" "$2" || rec "$@"; }   # rec_once KIND KEY [FIELD...]: only the first time for that key

note_change() { rec_once note "$*"; }       # something a restore cannot undo; shown by --list-changes

track_mkdir() {  # track_mkdir DIR: record the directories mkdir -p would newly create (outermost first)
    local d="$1" missing=()
    while [[ ! -e "$d" && "$d" != / && "$d" != . ]]; do missing=("$d" "${missing[@]}"); d="$(dirname "$d")"; done
    for d in "${missing[@]}"; do rec_once dir "$d"; done
}

mkd() { local d; for d in "$@"; do track_mkdir "$d"; done; mkdir -p "$@"; }

_backup_of() { echo "$(state_dir)/backup/$(printf %s "$1" | sha1sum | cut -c1-20)"; }

track_file() {  # track_file PATH [KIND]: call BEFORE creating or replacing a file or folder
    local p="$1" kind="${2:-file}" b
    rec_has "$kind" "$p" && return 0
    if [[ -e "$p" || -L "$p" ]]; then
        b="$(_backup_of "$p")"; mkdir -p "$(dirname "$b")"; rm -rf "$b"
        cp -a "$p" "$b" 2>/dev/null || sudo cp -a "$p" "$b" || true
        rec "$kind" "$p" replaced "$b"
    else
        rec "$kind" "$p" created
    fi
}

track_sys() { track_file "$1" sys; }   # the same for a system file that is written with sudo

track_new() {  # track_new DIR COMMAND...: run a command; whatever it newly puts in DIR is recorded as created
    local dir="$1" e; shift
    local before; before="$(ls -A "$dir" 2>/dev/null)"
    "$@"
    while IFS= read -r e; do [[ -n "$e" ]] && rec_once file "$dir/$e" created
    done < <(comm -13 <(echo "$before") <(ls -A "$dir" 2>/dev/null))
}

track_proc() { local n; for n in "$@"; do rec_once proc "$n"; done; }   # a program the installer starts

xf_record() {  # xf_record CHANNEL PROPERTY TYPE: remember the current value (or that it is absent)
    rec_has xf "$1" "$2" && return 0
    local out items
    if out="$(xfconf-query -c "$1" -p "$2" 2>/dev/null)"; then
        if [[ "$out" == "Value is an array"* ]]; then
            items="$(tail -n +3 <<<"$out" | paste -sd $'\x1e' -)"
            rec xf "$1" "$2" "$3" array "$items"
        else
            rec xf "$1" "$2" "$3" scalar "$out"
        fi
    else
        rec xf "$1" "$2" absent - ""
    fi
}

gs_record() {  # gs_record SCHEMA KEY: the user's own value (nothing recorded = it was at its default)
    local path="/${1//./\/}/$2"
    rec_has gs "$path" || rec gs "$path" "$(dconf read "$path" 2>/dev/null)"
}

gset() { gs_record "$1" "$2"; gsettings set "$@"; }   # gset SCHEMA KEY VALUE

dconf_load() {  # dconf_load PATH < keyfile: like `dconf load`, remembering the old settings there
    if ! rec_has dconf "$1"; then
        local b; b="$(_backup_of "dconf:$1")"; mkdir -p "$(dirname "$b")"
        dconf dump "$1" > "$b" 2>/dev/null || : > "$b"
        rec dconf "$1" "$b"
    fi
    dconf load "$1"
}

unit_record() {  # unit_record system|user UNIT: remember whether it was enabled and running
    local sc=() en act
    [[ "$1" == user ]] && sc=(--user)
    rec_has unit "$1" "$2" && return 0
    en="$(systemctl "${sc[@]}" is-enabled "$2" 2>/dev/null || true)"
    act="$(systemctl "${sc[@]}" is-active "$2" 2>/dev/null || true)"
    rec unit "$1" "$2" "${en:-unknown}" "${act:-unknown}"
}

# Replace the block between start and end tags in a file, or append it. Prints "changed".
upsert_block() {
    local file="$1" start="$2" end="$3" body="$4"
    if ! rec_has block "$file" "$start"; then
        if [[ -e "$file" ]]; then rec block "$file" "$start" "$end" existed
        else track_mkdir "$(dirname "$file")"; rec block "$file" "$start" "$end" created; fi
    fi
    mkdir -p "$(dirname "$file")"; touch "$file"
    python3 -I - "$file" "$start" "$end" "$body" <<'PY'
import sys, pathlib, re
path, start, end, body = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
block = f"{start}\n{body.rstrip()}\n{end}"
text = path.read_text()
pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.DOTALL)
new = pattern.sub(lambda _: block, text) if pattern.search(text) else (text.rstrip("\n") + "\n\n" + block + "\n").lstrip("\n")
if new != text:
    path.write_text(new)
    print("changed")
PY
}

# Copy SRC to DEST (in $HOME), filling in @HOME@; keeps a backup of a different file. Prints "changed".
install_file() {
    local src="$1" dest="$2" tmp
    tmp="$(mktemp)"; sed "s|@HOME@|$HOME|g" "$src" > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rec_has file "$dest" || rec file "$dest" created    # identical to ours: put there by an earlier install
        rm -f "$tmp"; return 0
    fi
    track_mkdir "$(dirname "$dest")"; mkdir -p "$(dirname "$dest")"
    track_file "$dest"
    if [[ -f "$dest" ]]; then
        local bak; bak="$dest.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$dest" "$bak"; rec file "$bak" created      # a restore tidies this copy up
    fi
    chmod 644 "$tmp"; mv "$tmp" "$dest"; echo changed
}

install_bin() {  # install_bin FILE...: into ~/.local/bin, executable
    mkd "$BIN"
    local f d; for f in "$@"; do
        d="$BIN/$(basename "$f")"
        if cmp -s "$f" "$d"; then rec_once file "$d" created; else track_file "$d"; fi
        install -m 755 "$f" "$d"
    done
}

xfset() {  # xfset CHANNEL PROPERTY TYPE VALUE  (creates the property when missing)
    local cur; cur="$(xfconf-query -c "$1" -p "$2" 2>/dev/null || true)"
    [[ "$cur" == "$4" ]] && return 0
    xf_record "$1" "$2" "$3"
    xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4"
}

xfset_strings() {  # xfset_strings CHANNEL PROPERTY VALUE...  (a string array, in this order)
    local ch="$1" prop="$2"; shift 2
    local want have v args=()
    want="$(printf '%s\n' "$@")"
    have="$(xfconf-query -c "$ch" -p "$prop" 2>/dev/null | tail -n +3)"
    [[ "$have" == "$want" ]] && return 0
    xf_record "$ch" "$prop" string
    for v in "$@"; do args+=(-t string -s "$v"); done
    xfconf-query -c "$ch" -p "$prop" -n --force-array "${args[@]}"
}

autostart_entry() {  # autostart_entry NAME COMMAND
    local f; f="$AUTOSTART/$(tr ' A-Z' '-a-z' <<<"$1").desktop"
    mkd "$AUTOSTART"; track_file "$f"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nX-GNOME-Autostart-enabled=true\n' "$1" "$2" > "$f"
}

restart_bg() {  # restart_bg PROCESS-NAME COMMAND...  (by exact process name, never by pattern)
    local name="$1"; shift
    track_proc "$name"
    pkill -u "$USER" -x "$name" 2>/dev/null || true
    sleep 0.3
    (setsid "$@" >/dev/null 2>&1 &)
}

build_c() {  # build_c FILE.c NAME [LIB...]: compile to ~/.local/bin/NAME when the source (or a shared header) changed
    local src="$1" name="$2"; shift 2
    local common stale=0 h
    common="$(dirname "$src")/../common"
    mkd "$SRC" "$BIN"; rec_once file "$SRC/$name" created; mkdir -p "$SRC/$name"
    cmp -s "$src" "$SRC/$name/$name.c" || stale=1
    [[ -x "$BIN/$name" ]] || stale=1
    if [[ -d "$common" ]]; then          # headers shared between programs: kept next to the sources, where "../common/x.h" finds them
        rec_once file "$SRC/common" created; mkdir -p "$SRC/common"
        for h in "$common"/*.h; do cmp -s "$h" "$SRC/common/$(basename "$h")" || stale=1; done
    fi
    if (( stale )); then
        need gcc gcc
        track_file "$BIN/$name"
        cp "$src" "$SRC/$name/$name.c"
        [[ -d "$common" ]] && cp "$common"/*.h "$SRC/common/"
        gcc -O2 -Wall -o "$BIN/$name" "$SRC/$name/$name.c" -lX11 "$@" || die "Build of $name failed (missing -dev packages?)"
        ok "Built $name"
    fi
}

# ---- top bar (xfce4-panel) --------------------------------------------------------------

panel_plugin_id() {  # plugin id of a type (one already in the panel first), or nothing
    local all in_panel id
    all="$(xfconf-query -c xfce4-panel -l -v | awk -v t="$1" '$1 ~ "^/plugins/plugin-[0-9]+$" && $2 == t {sub("/plugins/plugin-","",$1); print $1}' | sort -n)"
    in_panel=" $(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null | tail -n +3 | tr '\n' ' ') "
    for id in $all; do [[ "$in_panel" == *" $id "* ]] && { echo "$id"; return; }; done
    head -n1 <<<"$all"
}

panel_new_plugin() {  # panel_new_plugin TYPE: create a plugin of that type, print its id
    local id
    id=$(( $(xfconf-query -c xfce4-panel -l | grep -oE '^/plugins/plugin-[0-9]+' | grep -oE '[0-9]+$' | sort -n | tail -1) + 1 ))
    xf_record xfce4-panel "/plugins/plugin-$id" string
    xfconf-query -c xfce4-panel -p "/plugins/plugin-$id" -n -t string -s "$1"
    echo "$id"
}

# The macOS menu bar order, left to right. genmon (the latency badge from net-badge/) only when
# that is installed; a type that's not in the panel is skipped.
PANEL_ORDER=(whiskermenu appmenu separator genmon systray xapp-status-plugin pulseaudio power-manager-plugin notification-plugin clock)

panel_apply_order() {  # put the panel's items in PANEL_ORDER, then refresh the spacing CSS
    local id type ids=()
    for type in "${PANEL_ORDER[@]}"; do
        [[ "$type" == genmon && ! -x "$BIN/net-badge" ]] && continue
        id="$(panel_plugin_id "$type")"
        [[ -n "$id" ]] && ids+=("$id") || { [[ "$type" == genmon ]] || warn "No '$type' item in the panel; skipped"; }
    done
    local want="${ids[*]}" have args=()
    have="$(xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids 2>/dev/null | tail -n +3 | tr '\n' ' ' | sed 's/ *$//')"
    for id in "${ids[@]}"; do args+=(-t int -s "$id"); done
    [[ "$have" == "$want" ]] || { xf_record xfce4-panel /panels/panel-1/plugin-ids int
        xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids --force-array "${args[@]}"; }
    # Xfce leaves no gap between status items; give each a 7 px margin. Panel item ids differ
    # per machine, so the CSS names (e.g. #genmon-16) are generated here.
    local names="" t battery
    for id in "${ids[@]}"; do
        t="$(xfconf-query -c xfce4-panel -p "/plugins/plugin-$id")"
        case "$t" in genmon|systray|xapp-status-plugin|pulseaudio|power-manager-plugin|notification-plugin)
            names+="${names:+, }#$t-$id";; esac
    done
    local css="/* breathing room between the top bar's status items (Xfce gives them none) */
${names:-#nothing} {
  margin-left: 7px;
  margin-right: 7px;
}"
    battery="$(panel_plugin_id power-manager-plugin)"
    [[ -n "$battery" ]] && css+="
/* the horizontal battery reads small at 16 px: draw it a bit larger */
#power-manager-plugin-$battery image {
  -gtk-icon-transform: scale(1.25);
}"
    upsert_block "$HOME/.config/gtk-3.0/gtk.css" "/* >>> $TAG: top bar spacing */" "/* <<< $TAG: top bar spacing */" "$css" >/dev/null
    (setsid xfce4-panel -r >/dev/null 2>&1 &)
}

# ---- packages ---------------------------------------------------------------------------

record_new_packages() {  # record_new_packages PKG...: note the ones not installed yet (a restore --packages removes them)
    local p
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || rec_once pkg "$p"
    done
}

ensure_packages() {  # ensure_packages PKG...: apt-install the ones not installed yet (asks for sudo)
    local p missing=()
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
    done
    (( ${#missing[@]} )) || return 0
    record_new_packages "${missing[@]}"
    info "Installing: ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
}

packages_of() {  # packages_of DIR: the package names listed in DIR/packages (# comments allowed)
    sed 's/#.*//' "$1/packages" 2>/dev/null | tr -s ' \n' '\n' | grep .
}
