"""The logic behind the macOS-style settings pages (no GUI here, so it can be tested).

Every page reads and writes the same places the rest of the project already uses:
  Desktop & Dock  Plank's dconf keys, the desktop-slide helper, hot-corners.conf
  Trackpad        Xfce's pointer settings (applied live by xfsettingsd) and `xinput` for the scroll
                  distance, which no Xfce window offers and which is re-applied at login
  Displays        ~/.config/auto-brightness.conf (screen)
  Keyboard        ~/.config/auto-brightness.conf (keyboard backlight)
"""
import configparser
import os
import re
import subprocess

CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")), "xfce-macos")
HOT_CORNERS_CONF = os.path.join(CONFIG_DIR, "hot-corners.conf")
TRACKPAD_CONF = os.path.join(CONFIG_DIR, "trackpad.conf")
BRIGHTNESS_CONF = os.path.join(os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
                               "auto-brightness.conf")
PLANK = "/net/launchpad/plank/docks/dock1/"


def run(cmd, **kw):
    """Run a command, return (exit code, stdout); never raises."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10, **kw)
        return r.returncode, r.stdout
    except (OSError, subprocess.TimeoutExpired):
        return 127, ""


# ---- Hot Corners ---------------------------------------------------------------------------

# the actions a corner can have, in the order macOS lists them (name shown, key stored)
HOT_ACTIONS = [
    ("none", "–"),
    ("mission-control", "Mission Control"),
    ("desktop", "Desktop"),
    ("launchpad", "Launchpad"),
    ("lock-screen", "Lock Screen"),
    ("display-sleep", "Put Display to Sleep"),
]
CORNERS = ("tl", "tr", "bl", "br")
HOT_DEFAULTS = {"tl": "none", "tr": "desktop", "bl": "none", "br": "mission-control"}


def load_hot_corners(path=None):
    path = path or HOT_CORNERS_CONF
    result = dict(HOT_DEFAULTS)
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(tl|tr|bl|br)\s*=\s*([\w-]+)", line)
                if m and m.group(2) in dict(HOT_ACTIONS):
                    result[m.group(1)] = m.group(2)
    except OSError:
        pass
    return result


def save_hot_corners(corners, path=None):
    path = path or HOT_CORNERS_CONF
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("# Hot Corners (Desktop & Dock settings). tl/tr/bl/br: top left, top right, bottom left,\n"
                "# bottom right. Actions: " + ", ".join(k for k, _ in HOT_ACTIONS) + "\n")
        for c in CORNERS:
            f.write(f"{c} = {corners.get(c, 'none')}\n")


# ---- Dock (Plank) --------------------------------------------------------------------------

def dconf_read(key, runner=run):
    code, out = runner(["dconf", "read", PLANK + key])
    out = out.strip()
    if code != 0 or not out:
        return None
    if out.startswith("'") and out.endswith("'"):
        return out[1:-1]
    if out in ("true", "false"):
        return out == "true"
    try:
        return int(out)
    except ValueError:
        return out


def dconf_write(key, value, runner=run):
    if isinstance(value, bool):
        text = "true" if value else "false"
    elif isinstance(value, int):
        text = str(value)
    else:
        text = "'" + str(value).replace("'", "") + "'"
    return runner(["dconf", "write", PLANK + key, text])[0] == 0


def dock_state(runner=run):
    """What the Dock settings page shows."""
    return {
        "size": dconf_read("icon-size", runner) or 48,
        "magnify": bool(dconf_read("zoom-enabled", runner)),
        "magnify_size": dconf_read("zoom-percent", runner) or 150,
        "position": dconf_read("position", runner) or "bottom",
        "autohide": dconf_read("hide-mode", runner) in ("auto", "intelligent", "dodge-active", "window-dodge",
                                                       "dodge-maximized"),
    }


def set_dock(key, value, runner=run):
    """key: size, magnify, magnify_size, position, autohide"""
    if key == "size":
        return dconf_write("icon-size", max(16, min(128, int(value))), runner)
    if key == "magnify":
        return dconf_write("zoom-enabled", bool(value), runner)
    if key == "magnify_size":
        return dconf_write("zoom-percent", max(100, min(400, int(value))), runner)
    if key == "position" and value in ("left", "right", "bottom"):
        return dconf_write("position", value, runner)
    if key == "autohide":
        return dconf_write("hide-mode", "auto" if value else "none", runner)
    return False


# ---- Trackpad ------------------------------------------------------------------------------

def find_touchpad(runner=run):
    """(device id, device name) of the touchpad: the pointer device that has libinput's tapping setting."""
    code, out = runner(["xinput", "list", "--id-only"])
    for dev in out.split():
        _, props = runner(["xinput", "list-props", dev])
        if "libinput Tapping Enabled" in props:
            name = runner(["xinput", "list", "--name-only", dev])[1].strip()
            return dev, name
    return None, None


def xfconf_device_key(name):
    """Xfce's name for a device in its pointers channel: spaces become underscores."""
    return re.sub(r"[ /]", "_", name or "")


def xinput_get(dev, prop, runner=run):
    _, out = runner(["xinput", "list-props", dev])
    for line in out.splitlines():
        m = re.match(r"\s*" + re.escape(prop) + r" \(\d+\):\s*(.*)", line)
        if m:
            return [v.strip() for v in m.group(1).split(",")]
    return None


def xinput_set(dev, prop, values, runner=run):
    return runner(["xinput", "set-prop", dev, prop] + [str(v) for v in values])[0] == 0


def scroll_speed_to_distance(speed):
    """The slider (1 slow .. 10 fast) as libinput's pixels of finger travel per scroll step."""
    return max(5, min(60, 40 - 3 * int(speed)))


def distance_to_scroll_speed(distance):
    return max(1, min(10, round((40 - int(distance)) / 3)))


def load_trackpad_conf(path=None):
    cp = configparser.ConfigParser()
    cp.read(path or TRACKPAD_CONF)
    s = cp["trackpad"] if cp.has_section("trackpad") else {}
    return {k: s[k] for k in ("scroll_distance", "speed") if k in s}


def save_trackpad_conf(values, path=None):
    path = path or TRACKPAD_CONF
    os.makedirs(os.path.dirname(path), exist_ok=True)
    cp = configparser.ConfigParser()
    cp["trackpad"] = {k: str(v) for k, v in values.items()}
    with open(path, "w") as f:
        f.write("# Trackpad settings kept by the Trackpad page and re-applied at login (macos-settings --apply)\n")
        cp.write(f)


def trackpad_state(runner=run):
    dev, name = find_touchpad(runner)
    if dev is None:
        return None
    one = lambda p, d: (xinput_get(dev, p, runner) or [d])[0]
    return {
        "device": dev, "name": name,
        "tap": one("libinput Tapping Enabled", "0") == "1",
        "natural": one("libinput Natural Scrolling Enabled", "0") == "1",
        "scroll_distance": int(one("libinput Scrolling Pixel Distance", "15")),
        "speed": float(one("libinput Accel Speed", "0")),
    }


def set_xfce_pointer(name, prop, value, runner=run):
    """Tap and natural scrolling go through Xfce's own settings: applied live and kept across logins."""
    key = xfconf_device_key(name)
    if prop == "natural":
        return runner(["xfconf-query", "-c", "pointers", "-p", f"/{key}/ReverseScrolling", "-n", "-t", "bool",
                       "-s", "true" if value else "false"])[0] == 0
    if prop == "tap":
        return runner(["xfconf-query", "-c", "pointers", "-p", f"/{key}/Properties/libinput_Tapping_Enabled",
                       "-n", "-t", "int", "-s", "1" if value else "0"])[0] == 0
    return False


def apply_trackpad_conf(runner=run, path=None):
    """At login: put back the scroll distance and tracking speed the Trackpad page saved."""
    saved = load_trackpad_conf(path)
    dev, _ = find_touchpad(runner)
    if dev is None:
        return False
    if "scroll_distance" in saved:
        xinput_set(dev, "libinput Scrolling Pixel Distance", [saved["scroll_distance"]], runner)
    if "speed" in saved:
        xinput_set(dev, "libinput Accel Speed", [saved["speed"]], runner)
    return True


# ---- Brightness (Displays and Keyboard pages) ----------------------------------------------

def load_brightness(path=None):
    cp = configparser.ConfigParser()
    cp.read(path or BRIGHTNESS_CONF)
    s = cp["auto-brightness"] if cp.has_section("auto-brightness") else {}
    on = lambda k: str(s.get(k, "true")).strip().lower() in ("1", "true", "yes", "on")
    return {"screen": on("screen"), "keyboard": on("keyboard")}


def save_brightness(screen, keyboard, path=None):
    path = path or BRIGHTNESS_CONF
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("[auto-brightness]\n"
                "# adjust brightness automatically from the light sensor (true/false)\n"
                f"screen = {'true' if screen else 'false'}\n"
                f"keyboard = {'true' if keyboard else 'false'}\n")


def has_light_sensor():
    import glob
    return bool(glob.glob("/sys/bus/iio/devices/iio:device*/in_illuminance_*"))


def has_keyboard_backlight():
    import glob
    return bool(glob.glob("/sys/class/leds/*kbd_backlight*"))


# ---- Spaces slide (Desktop & Dock) ---------------------------------------------------------

def slide_is_on(runner=run):
    return runner(["desktop-slide", "status"])[1].strip() == "on"


def set_slide(on, runner=run):
    return runner(["desktop-slide", "on" if on else "off"])[0] == 0
