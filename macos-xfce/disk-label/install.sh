#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# disk-label: a "Macintosh HD / 91 GB free" icon on the desktop.
install_bin "$HERE/disk-label"
autostart_entry "Disk Label" "$BIN/disk-label"
restart_bg disk-label "$BIN/disk-label"
ok "Disk icon with free space on the desktop"
