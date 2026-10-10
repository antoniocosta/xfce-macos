"""The logic behind the setup app (no GUI here, so it can be tested)."""
import os
import re

HERE = os.path.dirname(os.path.realpath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # the checkout: .../linux-utilities
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def strip_ansi(text):
    return ANSI_RE.sub("", text)


def installer(root=None):
    """The main installer; LU_SETUP_INSTALLER replaces it (for tests)."""
    return os.environ.get("LU_SETUP_INSTALLER") or os.path.join(root or ROOT, "macos-xfce", "install.sh")


# the optional extras shown as checkboxes: (folder under extras/, what the user reads)
EXTRAS = [
    ("net-badge", "Network latency in the menu bar"),
    ("vpntray", "VPN panel in the menu bar (AdGuard VPN)"),
]


def available_extras(root=None):
    base = os.path.join(root or ROOT, "extras")
    return [(d, label) for d, label in EXTRAS if os.path.isfile(os.path.join(base, d, "install.sh"))]


def install_commands(trim=False, english=False, extras=(), root=None):
    """The commands an Install runs, in order. The first one asks for the administrator password once,
    so the rest of the installer can use sudo without asking again."""
    cmds = [["sudo", "-A", "-v"]]
    main = ["bash", installer(root)]
    if trim:
        main.append("--trim")
    if english:
        main.append("--english-only")
    cmds.append(main)
    for name in extras:
        cmds.append(["bash", os.path.join(root or ROOT, "extras", name, "install.sh")])
    return cmds


def restore_commands(dry_run=False, packages=False, root=None):
    cmds = [["bash", installer(root), "--restore"]]
    if dry_run:
        cmds[0].append("--dry-run")
    else:
        cmds[0].append("--yes")
    if packages:
        cmds[0].append("--packages")
    return cmds


def list_changes_commands(root=None):
    return [["bash", installer(root), "--list-changes"]]


def child_env(askpass):
    """No terminal: sudo asks through a small graphical prompt."""
    env = dict(os.environ)
    env["SUDO_ASKPASS"] = askpass
    env.pop("LU_NO_REFRESH", None)
    return env
