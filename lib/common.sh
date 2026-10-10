# Shared helpers for the install scripts (sourced, not run).
# Every helper checks before it changes anything, so the installers are safe to re-run.

BIN="$HOME/.local/bin"
SRC="$HOME/.local/src"
AUTOSTART="$HOME/.config/autostart"
TAG="linux-utilities"            # marks the blocks we add to files we share with other tools
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

# Replace the block between start and end tags in a file, or append it. Prints "changed".
upsert_block() {
    local file="$1" start="$2" end="$3" body="$4"
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
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then rm -f "$tmp"; return 0; fi
    [[ -f "$dest" ]] && cp -p "$dest" "$dest.bak.$(date +%Y%m%d-%H%M%S)"
    chmod 644 "$tmp"; mv "$tmp" "$dest"; echo changed
}

install_bin() {  # install_bin FILE...: into ~/.local/bin, executable
    mkdir -p "$BIN"
    local f; for f in "$@"; do install -m 755 "$f" "$BIN/$(basename "$f")"; done
}

xfset() {  # xfset CHANNEL PROPERTY TYPE VALUE  (creates the property when missing)
    local cur; cur="$(xfconf-query -c "$1" -p "$2" 2>/dev/null || true)"
    [[ "$cur" == "$4" ]] && return 0
    xfconf-query -c "$1" -p "$2" -n -t "$3" -s "$4"
}

xfset_strings() {  # xfset_strings CHANNEL PROPERTY VALUE...  (a string array, in this order)
    local ch="$1" prop="$2"; shift 2
    local want have v args=()
    want="$(printf '%s\n' "$@")"
    have="$(xfconf-query -c "$ch" -p "$prop" 2>/dev/null | tail -n +3)"
    [[ "$have" == "$want" ]] && return 0
    for v in "$@"; do args+=(-t string -s "$v"); done
    xfconf-query -c "$ch" -p "$prop" -n --force-array "${args[@]}"
}

autostart_entry() {  # autostart_entry NAME COMMAND
    mkdir -p "$AUTOSTART"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\nX-GNOME-Autostart-enabled=true\n' "$1" "$2" \
        > "$AUTOSTART/$(tr ' A-Z' '-a-z' <<<"$1").desktop"
}

restart_bg() {  # restart_bg PROCESS-NAME COMMAND...  (by exact process name, never by pattern)
    local name="$1"; shift
    pkill -u "$USER" -x "$name" 2>/dev/null || true
    sleep 0.3
    (setsid "$@" >/dev/null 2>&1 &)
}

build_c() {  # build_c FILE.c NAME [LIB...]: compile to ~/.local/bin/NAME when the source changed
    local src="$1" name="$2"; shift 2
    mkdir -p "$SRC/$name" "$BIN"
    if ! cmp -s "$src" "$SRC/$name/$name.c" || [[ ! -x "$BIN/$name" ]]; then
        need gcc gcc
        cp "$src" "$SRC/$name/$name.c"
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
    [[ "$have" == "$want" ]] || xfconf-query -c xfce4-panel -p /panels/panel-1/plugin-ids --force-array "${args[@]}"
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

ensure_packages() {  # ensure_packages PKG...: apt-install the ones not installed yet (asks for sudo)
    local p missing=()
    for p in "$@"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
    done
    (( ${#missing[@]} )) || return 0
    info "Installing: ${missing[*]}"
    sudo apt-get install -y "${missing[@]}"
}

packages_of() {  # packages_of DIR: the package names listed in DIR/packages (# comments allowed)
    sed 's/#.*//' "$1/packages" 2>/dev/null | tr -s ' \n' '\n' | grep .
}
