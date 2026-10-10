# shellcheck shell=bash
# Undo what the installers recorded (see "change record" in common.sh). Sourced, not run.
#   lu_restore MODE [--packages] [--yes]     MODE: run | dry | list
# Safe to run twice and when parts are already gone. Packages are only touched with --packages.

_R_FAIL=0 _R_NOSUDO=0 _R_DRY=0 _R_REFRESH=""

_r_try() { "$@" || { _R_FAIL=$((_R_FAIL + 1)); warn "failed: $*"; return 1; }; }
_r_sudo() { (( _R_NOSUDO )) && { _R_FAIL=$((_R_FAIL + 1)); warn "no sudo, skipped: $*"; return 1; }; _r_try sudo "$@"; }

_r_block_remove() {  # FILE START END CREATED
    python3 -I - "$@" <<'PY'
import sys, pathlib, re
path, start, end, created = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
if not path.exists():
    sys.exit(0)
text = path.read_text()
m = re.search(re.escape(start) + r".*?" + re.escape(end) + r"\n?", text, re.DOTALL)
if m:
    before, after = text[:m.start()], text[m.end():]
    if not after.strip():
        new = before.rstrip("\n") + ("\n" if before.strip() else "")
    elif not before.strip():
        new = after.lstrip("\n")
    else:
        new = before.rstrip("\n") + "\n\n" + after.lstrip("\n")
    if new != text:
        path.write_text(new)
        text = new
if created == "created" and not text.strip():
    path.unlink()
PY
}

_r_xf() {  # CHANNEL PROPERTY TYPE KIND VALUE
    local ch="$1" prop="$2" type="$3" kind="$4" val="$5" it args=() items
    if [[ "$type" == absent ]]; then
        xfconf-query -c "$ch" -p "$prop" -r -R 2>/dev/null || true
    elif [[ "$kind" == array ]]; then
        IFS=$'\x1e' read -ra items <<<"$val"
        for it in "${items[@]}"; do args+=(-t "$type" -s "$it"); done
        _r_try xfconf-query -c "$ch" -p "$prop" -n --force-array "${args[@]}"
    else
        _r_try xfconf-query -c "$ch" -p "$prop" -n -t "$type" -s "$val"
    fi
}

_r_unit() {  # SCOPE UNIT ENABLED ACTIVE : put the unit's enabled/running state back
    local sc="$1" u="$2" en="$3" act="$4" run=(systemctl) q=(systemctl)
    if [[ "$sc" == user ]]; then run=(systemctl --user); q=(systemctl --user)
    else
        (( _R_NOSUDO )) && { _R_FAIL=$((_R_FAIL + 1)); warn "no sudo, skipped: $u"; return 0; }
        run=(sudo systemctl)
    fi
    "${q[@]}" list-unit-files "$u" --no-legend 2>/dev/null | grep -q . || return 0   # package gone
    [[ "$en" == masked ]] || "${run[@]}" unmask "$u" 2>/dev/null || true
    case "$en" in
        enabled|enabled-runtime) "${run[@]}" enable "$u" 2>/dev/null || true ;;
        disabled)                "${run[@]}" disable "$u" 2>/dev/null || true ;;
        masked)                  "${run[@]}" mask "$u" 2>/dev/null || true ;;
    esac
    if [[ "$act" == active ]]; then "${run[@]}" start "$u" 2>/dev/null || true
    elif [[ "$en" == disabled || "$en" == masked ]]; then "${run[@]}" stop "$u" 2>/dev/null || true; fi
    return 0
}

_r_describe_unit() {
    case "$3" in
        masked) echo "$1 service $2: mask again" ;;
        enabled|enabled-runtime) echo "$1 service $2: enable${4:+ ($4 before)}" ;;
        disabled) echo "$1 service $2: disable again" ;;
        *) echo "$1 service $2: unmask" ;;
    esac
}

lu_restore() {
    local mode="$1"; shift
    local packages=0 yes=0 a
    for a in "$@"; do case "$a" in --packages) packages=1 ;; --yes) yes=1 ;; esac; done
    local dir log; dir="$(state_dir)"; log="$dir/changes"
    [[ -s "$log" ]] || { info "Nothing recorded to undo (no $log)"; return 0; }
    local recs=() r n
    mapfile -t recs < "$log"
    n=${#recs[@]}
    _R_DRY=0; [[ "$mode" != run ]] && _R_DRY=1
    local verb="undo"; [[ "$mode" == dry ]] && verb="would undo"; [[ "$mode" == list ]] && verb="-"

    local f1 f2 f3 f4 f5 kind needs_sudo=0
    for r in "${recs[@]}"; do
        IFS=$'\x1f' read -r kind f1 f2 f3 f4 f5 <<<"$r"
        case "$kind" in sys) needs_sudo=1 ;; unit) [[ "$f1" == system ]] && needs_sudo=1 ;;
            pkg|pkgrm) (( packages )) && needs_sudo=1 ;; esac
    done

    if [[ "$mode" == run ]]; then
        if (( ! yes )); then
            local ans=""
            printf 'Undo %d recorded changes (%s)? [y/N] ' "$n" "$dir" >&2
            { read -r ans </dev/tty; } 2>/dev/null || read -r ans || true
            [[ "$ans" == [yY]* ]] || { info "Nothing changed"; return 0; }
        fi
        if (( needs_sudo )); then
            info "Some changes are system-wide: asking for sudo once"
            sudo -v || { _R_NOSUDO=1; warn "No sudo: system-wide changes will be skipped"; }
        fi
    fi

    say() { printf '  %s %s\n' "$verb" "$*"; }
    local i desc notes=() inst=() rm_=() refresh=0 toshy=0 apt_update=0

    # 1. programs the installer started (the wrappers first, so they cannot restart their children)
    for r in "${recs[@]}"; do
        IFS=$'\x1f' read -r kind f1 f2 f3 f4 f5 <<<"$r"
        [[ "$kind" == proc ]] || continue
        say "stop $f1"
        (( _R_DRY )) || pkill -u "$(id -un)" -x "$f1" 2>/dev/null || true
    done

    # 2. everything else, newest first
    for (( i = n - 1; i >= 0; i-- )); do
        IFS=$'\x1f' read -r kind f1 f2 f3 f4 f5 <<<"${recs[i]}"
        [[ "$kind" =~ ^(file|sys|dir)$ && ( -z "$f1" || "$f1" == / ) ]] && continue
        case "$kind" in
            file)
                if [[ "$f2" == created ]]; then desc="remove $f1"
                else desc="put the original back: $f1"; fi
                say "$desc"; (( _R_DRY )) && continue
                _r_try rm -rf -- "$f1"
                [[ "$f2" == replaced ]] && { if [[ -e "$f3" || -L "$f3" ]]; then
                    mkdir -p "$(dirname "$f1")"; _r_try cp -a "$f3" "$f1"
                else warn "backup of $f1 is missing"; _R_FAIL=$((_R_FAIL + 1)); fi; }
                [[ "$f1" == */toshy/* ]] && toshy=1
                ;;
            sys)
                if [[ "$f2" == created ]]; then desc="remove $f1 (sudo)"; else desc="put the original back: $f1 (sudo)"; fi
                say "$desc"; (( _R_DRY )) && continue
                _r_sudo rm -rf -- "$f1"
                [[ "$f2" == replaced ]] && _r_sudo cp -a "$f3" "$f1"
                case "$f1" in /etc/apt/*|/usr/share/keyrings/*) apt_update=1 ;; esac
                [[ "$f1" == /etc/default/zramswap ]] && { sudo systemctl restart zramswap 2>/dev/null || true; }
                ;;
            dir)
                say "remove $f1 if empty"; (( _R_DRY )) || rmdir -- "$f1" 2>/dev/null || true ;;
            block)
                say "remove the '$TAG' block from $f1"; (( _R_DRY )) && continue
                _r_try _r_block_remove "$f1" "$f2" "$f3" "$f4"; refresh=1; [[ "$f1" == */toshy/* ]] && toshy=1 ;;
            xf)
                if [[ "$f3" == absent ]]; then desc="xfconf $f1 $f2: remove the setting"
                else desc="xfconf $f1 $f2: back to '${f5//$'\x1e'/, }'"; fi
                say "$desc"; (( _R_DRY )) && continue
                _r_xf "$f1" "$f2" "$f3" "$f4" "$f5"; refresh=1 ;;
            gs)
                if [[ -z "$f2" ]]; then desc="dconf $f1: back to the default"; else desc="dconf $f1: back to $f2"; fi
                say "$desc"; (( _R_DRY )) && continue
                if [[ -z "$f2" ]]; then _r_try dconf reset "$f1"; else _r_try dconf write "$f1" "$f2"; fi ;;
            dconf)
                say "dconf $f1: back to the settings it had"; (( _R_DRY )) && continue
                _r_try dconf reset -f "$f1"; [[ -s "$f2" ]] && { _r_try dconf load "$f1" < "$f2"; } ;;
            unit)
                say "$(_r_describe_unit "$f1" "$f2" "$f3" "$f4")"; (( _R_DRY )) || _r_unit "$f1" "$f2" "$f3" "$f4" ;;
            pkg)    inst+=("$f1") ;;
            pkgrm)  rm_+=("$f1") ;;
            note)   notes+=("$f1") ;;
        esac
    done

    # 3. packages, only on request
    if (( ${#inst[@]} )); then
        if (( packages )); then
            say "apt remove the packages the installer added: ${inst[*]}"
            (( _R_DRY )) || _r_sudo apt-get remove -y "${inst[@]}"
        else
            say "keep ${#inst[@]} installed packages (add --packages to remove: ${inst[*]})"
        fi
    fi
    if (( ${#rm_[@]} )); then
        if (( packages )); then
            say "apt install again the packages the installer removed: ${rm_[*]}"
            (( _R_DRY )) || _r_sudo apt-get install -y "${rm_[@]}"
        else
            say "keep ${#rm_[@]} removed packages removed (--packages installs them again: ${rm_[*]})"
        fi
    fi
    (( apt_update && ! _R_DRY )) && { _r_sudo apt-get update -q || true; }

    if (( ${#notes[@]} )); then
        printf '\nCannot be undone automatically:\n'
        printf '  ! %s\n' "${notes[@]}"
    fi
    [[ "$mode" == list ]] && return 0
    (( _R_DRY )) && { info "Dry run: nothing was changed"; return 0; }

    # let running desktop parts notice (never in tests: LU_NO_REFRESH)
    if [[ -z "${LU_NO_REFRESH:-}" ]]; then
        (( toshy )) && systemctl --user restart toshy-config.service 2>/dev/null || true
        if (( refresh )) && [[ -n "${DISPLAY:-}" ]]; then
            pgrep -u "$(id -un)" -x xfwm4 >/dev/null && (setsid xfwm4 --replace >/dev/null 2>&1 &)
            pgrep -u "$(id -un)" -x xfce4-panel >/dev/null && (setsid xfce4-panel -r >/dev/null 2>&1 &)
        fi
    fi

    if (( _R_FAIL )); then
        warn "$_R_FAIL step(s) failed; the record is kept in $dir so you can run the restore again"
        return 1
    fi
    rm -rf "$dir"
    ok "Restored. Log out and back in to finish (the global menu and keyboard setup load at login)."
}
