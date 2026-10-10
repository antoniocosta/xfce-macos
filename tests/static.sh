#!/usr/bin/env bash
# Static checks: everything parses and builds cleanly, configs are valid, nothing private leaked.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

t_begin "Shell scripts parse"
mapfile -t shells < <(git ls-files | while read -r f; do
    [[ -f "$f" ]] && head -1 "$f" | grep -qE '^#!.*(bash|/sh)' && echo "$f"; done; echo lib/common.sh; echo lib/restore.sh; echo tests/lib.sh)
for f in "${shells[@]}"; do check "$f" bash -n "$f"; done

if command -v shellcheck >/dev/null; then
    t_begin "shellcheck (errors only)"
    for f in "${shells[@]}"; do check "$f" shellcheck -S error -x "$f"; done
fi

t_begin "C programs build without warnings"
tmp="$(mktemp -d)"
check "hotcorner"       gcc -O2 -Wall -Wextra -Werror -o "$tmp/a" macos-xfce/hotcorner/hotcorner.c -lX11
check "fullscreen"      gcc -O2 -Wall -Wextra -Werror -o "$tmp/b" macos-xfce/fullscreen/fullscreen.c -lX11 -lXi -lcairo -lm
check "mission-control" gcc -O2 -Wall -Wextra -Werror -o "$tmp/c" macos-xfce/mission-control/mission-control.c \
                        -lX11 -lXcomposite -lcairo -ljpeg -lm
rm -rf "$tmp"

t_begin "Python scripts compile"
for f in $(git ls-files | while read -r f; do [[ -f "$f" ]] && head -1 "$f" | grep -qE '^#!.*python' && echo "$f"; done); do
    check "$f" python3 -I -c "import sys; compile(open(sys.argv[1]).read(), sys.argv[1], 'exec')" "$f"
done

t_begin "Config files are valid"
check "touchegg.conf is XML" python3 -I -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" \
    macos-xfce/files/.config/touchegg/touchegg.conf
check "every installer is executable" bash -c 'for f in $(git ls-files "*install.sh"); do [[ -x $f ]] || exit 1; done'
check "every program the installers copy is executable" bash -c '
    for f in macos-xfce/*/*; do
        [[ -f $f ]] && head -1 "$f" | grep -q "^#!" && [[ ! -x $f ]] && { echo "$f"; exit 1; }
    done; exit 0'

t_begin "Nothing private in this public repo"
check "no private repo names, hosts or accounts" bash -c \
    '! git grep -qIiE "scriptsmisc|fleet|peekr|herdr|abmc|air12|uncorp|gmx\\." -- . ":!tests/static.sh"'

t_begin "README covers every part"
for d in macos-xfce/*/; do
    [[ -f "$d/install.sh" ]] || continue
    n="$(basename "$d")"
    check "README has a section for $n" grep -q "^## $n\$" README.md
done

t_summary
