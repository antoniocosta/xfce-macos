#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../lib/common.sh"
require_xfce
mapfile -t pkgs < <(packages_of "$HERE"); ensure_packages "${pkgs[@]}"
# ssh-keyring: unlock your SSH key at login from the login keyring, like macOS's Keychain.
#   ./install.sh [KEY]    (default ~/.ssh/id_ed25519)
KEY="${1:-$HOME/.ssh/id_ed25519}"
[[ -f "$KEY" ]] || die "No SSH key at $KEY"
install_bin "$HERE/ssh-keyring"
if [[ "$KEY" == "$HOME/.ssh/id_ed25519" ]]; then
    autostart_entry "Unlock SSH key (keyring)" "$BIN/ssh-keyring unlock"
else
    autostart_entry "Unlock SSH key (keyring)" "env SSH_KEYRING_KEY=$KEY $BIN/ssh-keyring unlock"
fi
SSH_KEYRING_KEY="$KEY" "$BIN/ssh-keyring" unlock >/dev/null 2>&1 \
    && ok "SSH key unlocked from the keyring; it will be at every login" \
    || info "Run \`ssh-keyring store\` once to save the key's passphrase in the login keyring"
