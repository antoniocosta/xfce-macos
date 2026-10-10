#!/usr/bin/python3 -I
"""A test window: win.py TITLE [--dialog] [--child TITLE SECONDS]

--dialog          the window says it is a dialog
--fullscreen      the window starts full screen
--child T S       after S seconds, open a second window titled T that belongs to this one
                  (transient for it), like an app's Save or Print dialog
"""
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import GLib, Gdk, Gtk  # noqa: E402

args = sys.argv[1:]
win = Gtk.Window(title=args[0])
win.set_default_size(400, 300)
if "--dialog" in args:
    win.set_type_hint(Gdk.WindowTypeHint.DIALOG)
win.connect("destroy", Gtk.main_quit)
if "--fullscreen" in args:
    win.fullscreen()
win.show_all()

if "--child" in args:
    i = args.index("--child")
    title, delay = args[i + 1], float(args[i + 2])

    def open_child():
        child = Gtk.Window(title=title)
        child.set_default_size(200, 120)
        child.set_transient_for(win)
        child.show_all()
        return False
    GLib.timeout_add(int(delay * 1000), open_child)

Gtk.main()
