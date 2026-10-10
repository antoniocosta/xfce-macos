#!/usr/bin/env bash
# Runs the tests.
#   tests/run.sh             everything that can run here (live tests need Xvfb)
#   tests/run.sh static      parsing, builds, configs, nothing private, README coverage
#   tests/run.sh unit        the installers' helpers
#   tests/run.sh live [NAME] behaviour in an invisible X display with its own window manager and
#                            settings: nothing shows on your screen, nothing touches your settings
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
what="${1:-all}"; shift || true
status=0
if [[ $what == all || $what == static ]]; then bash "$HERE/static.sh" || status=1; fi
if [[ $what == all || $what == unit ]];   then bash "$HERE/unit.sh"   || status=1; fi
if [[ $what == all || $what == live ]]; then
    if command -v Xvfb >/dev/null; then
        bash "$HERE/live.sh" "$@" || status=1
    else
        printf '\nlive tests skipped: install Xvfb (sudo apt install xvfb)\n'
        [[ $what == live ]] && status=1
    fi
fi
exit $status
