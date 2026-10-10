# shellcheck shell=bash
# Test helpers (sourced). Each test file calls `t_begin NAME`, then checks, then `t_end`.

T_PASS=${T_PASS:-0}
T_FAIL=${T_FAIL:-0}
T_FAILED=${T_FAILED:-}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

t_begin() { printf '\n\033[1;35m== %s\033[0m\n' "$1"; }

pass() { T_PASS=$((T_PASS + 1)); printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { T_FAIL=$((T_FAIL + 1)); T_FAILED+="  - $1"$'\n'; printf '  \033[31mFAIL\033[0m  %s%s\n' "$1" "${2:+ ($2)}"; }

check() {  # check "description" command...   (passes when the command succeeds)
    local d="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}

eq() {  # eq "description" got want
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "got '$2', want '$3'"; fi
}

wait_until() {  # wait_until SECONDS command...   (succeeds as soon as the command does)
    local tries; tries=$(awk -v s="$1" 'BEGIN { print int(s * 20) + 1 }'); shift
    while (( tries-- > 0 )); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    return 1
}

t_summary() {
    printf '\n%d passed, %d failed\n' "$T_PASS" "$T_FAIL"
    [[ -n "$T_FAILED" ]] && printf 'Failed:\n%s' "$T_FAILED"
    (( T_FAIL == 0 ))
}
