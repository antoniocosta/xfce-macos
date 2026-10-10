#!/usr/bin/python3
"""Helpers for docs/screenshots.sh. They only talk to the display they are given (DISPLAY).

  capture.py shot OUT.png [X Y W H]        the screen (or a region) as a PNG, scaled to 1200 px wide at most
  capture.py window OUT.png WINDOW-ID      one window, with its frame
  capture.py settings PANE OUT.png         a settings page (trackpad shows a plausible fake touchpad)
  capture.py setup OUT.png                 the setup window with a short example log
"""
import importlib.machinery
import importlib.util
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
MAX_WIDTH = 1200


def save(pixbuf, out):
    if pixbuf.get_width() > MAX_WIDTH:
        h = round(pixbuf.get_height() * MAX_WIDTH / pixbuf.get_width())
        pixbuf = pixbuf.scale_simple(MAX_WIDTH, h, 2)          # bilinear
    pixbuf.savev(out, "png", ["compression"], ["9"])
    print(f"{out}: {pixbuf.get_width()}x{pixbuf.get_height()}, {os.path.getsize(out) // 1024} KB")


def screen_region(x=0, y=0, w=None, h=None):
    root = Gdk.get_default_root_window()
    w = w or root.get_width() - x
    h = h or root.get_height() - y
    return Gdk.pixbuf_get_from_window(root, x, y, w, h)


def window_geometry(wid):
    """The window including its frame (title bar and borders), from xwininfo and xprop."""
    info = subprocess.run(["xwininfo", "-id", wid], capture_output=True, text=True).stdout
    vals = {}
    for line in info.splitlines():
        for key in ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height"):
            if line.strip().startswith(key + ":"):
                vals[key] = int(line.split(":")[1])
    ext = subprocess.run(["xprop", "-id", wid, "_NET_FRAME_EXTENTS"], capture_output=True, text=True).stdout
    left = right = top = bottom = 0
    if "=" in ext:
        left, right, top, bottom = [int(v) for v in ext.split("=")[1].split(",")]
    x = vals["Absolute upper-left X"] - left
    y = vals["Absolute upper-left Y"] - top
    return x, y, vals["Width"] + left + right, vals["Height"] + top + bottom


def load_module(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def run_and_grab(window, out, delay=900):
    """Show a Gtk window, wait for it to draw, save its picture, quit."""
    window.show_all()

    def grab():
        gdk = window.get_window()
        pb = Gdk.pixbuf_get_from_window(gdk, 0, 0, gdk.get_width(), gdk.get_height())
        save(pb, out)
        Gtk.main_quit()
        return False
    GLib.timeout_add(delay, grab)
    Gtk.main()


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "shot":
        out = sys.argv[2]
        region = [int(v) for v in sys.argv[3:7]] if len(sys.argv) >= 7 else []
        save(screen_region(*region), out)
    elif cmd == "window":
        x, y, w, h = window_geometry(sys.argv[3])
        save(screen_region(x, y, w, h), sys.argv[2])
    elif cmd == "settings":
        pane, out = sys.argv[2], sys.argv[3]
        folder = os.path.join(ROOT, "macos-xfce", "settings")
        sys.path.insert(0, folder)
        ms = load_module(os.path.join(folder, "macos-settings"), "macos_settings")
        if pane == "trackpad":                     # a plausible touchpad, so the page has something to show
            ms.core.trackpad_state = lambda *a, **k: {
                "device": "9", "name": "Touchpad", "tap": True, "natural": True,
                "scroll_distance": 12, "speed": 0.2}
        ms.core.slide_is_on = lambda *a, **k: True      # the slide is on after an install (picom is not in this scene)
        css = Gtk.CssProvider()
        css.load_from_data(ms.CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        run_and_grab(ms.PANES[pane](), out)
    elif cmd == "setup":
        folder = os.path.join(ROOT, "macos-xfce", "setup-app")
        sys.path.insert(0, folder)
        app = load_module(os.path.join(folder, "xfce-macos-setup"), "xfce_macos_setup")
        s = app.Setup()
        s.say("$ bash macos-xfce/install.sh\n[INFO] Packages\n[OK]   Packages installed\n"
              "[OK]   WhiteSur dark theme, macOS cursors, Inter font, dark mode\n"
              "[OK]   Menu bar at the top with the global menu, in macOS order\n"
              "[OK]   Mission Control (F3, Ctrl+Up, bottom-right corner)\n"
              "[OK]   Dock set up\n")
        s.status.set_text("Done. Log out and back in once so the global menu and Toshy start cleanly.")
        run_and_grab(s.win, sys.argv[3] if len(sys.argv) > 3 else sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
