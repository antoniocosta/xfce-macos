"""Tests for settings_core (no GUI, no real settings: commands go through a fake runner)."""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import settings_core as core  # noqa: E402


class Fake:
    """A fake command runner: records the commands, answers from a table."""
    def __init__(self, answers=None):
        self.calls, self.answers = [], answers or {}

    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        return self.answers.get(tuple(cmd), (0, ""))


class HotCorners(unittest.TestCase):
    def test_defaults_without_a_file(self):
        self.assertEqual(core.load_hot_corners("/nonexistent"),
                         {"tl": "none", "tr": "desktop", "bl": "none", "br": "mission-control"})

    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "sub", "hc.conf")
            core.save_hot_corners({"tl": "launchpad", "tr": "none", "bl": "lock-screen", "br": "display-sleep"}, p)
            self.assertEqual(core.load_hot_corners(p),
                             {"tl": "launchpad", "tr": "none", "bl": "lock-screen", "br": "display-sleep"})

    def test_unknown_actions_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "hc.conf")
            open(p, "w").write("tl = rm-rf\nbr = launchpad\n# tr = none\n")
            got = core.load_hot_corners(p)
            self.assertEqual((got["tl"], got["br"], got["tr"]), ("none", "launchpad", "desktop"))


class Dock(unittest.TestCase):
    def test_reads_typed_values(self):
        fake = Fake({("dconf", "read", core.PLANK + "icon-size"): (0, "20\n"),
                     ("dconf", "read", core.PLANK + "zoom-enabled"): (0, "true\n"),
                     ("dconf", "read", core.PLANK + "position"): (0, "'bottom'\n"),
                     ("dconf", "read", core.PLANK + "hide-mode"): (0, "'auto'\n"),
                     ("dconf", "read", core.PLANK + "zoom-percent"): (0, "")})
        st = core.dock_state(fake)
        self.assertEqual((st["size"], st["magnify"], st["position"], st["autohide"], st["magnify_size"]),
                         (20, True, "bottom", True, 150))

    def test_writes_are_typed_and_clamped(self):
        fake = Fake()
        core.set_dock("size", 500, fake)
        core.set_dock("magnify", True, fake)
        core.set_dock("magnify_size", 50, fake)
        core.set_dock("position", "left", fake)
        core.set_dock("autohide", False, fake)
        self.assertEqual([c[3] for c in fake.calls], ["128", "true", "100", "'left'", "'none'"])

    def test_bad_position_is_refused(self):
        self.assertFalse(core.set_dock("position", "top; reboot", Fake()))


class Trackpad(unittest.TestCase):
    PROPS = ("libinput Tapping Enabled (308):\t1\nlibinput Natural Scrolling Enabled (316):\t0\n"
             "libinput Scrolling Pixel Distance (343):\t15\nlibinput Accel Speed (328):\t-0.040000\n"
             "libinput Disable While Typing Enabled (318):\t1\n")

    def runner(self):
        return Fake({("xinput", "list", "--id-only"): (0, "3\n7\n"),
                     ("xinput", "list-props", "3"): (0, "Device Enabled (1):\t1\n"),
                     ("xinput", "list-props", "7"): (0, self.PROPS),
                     ("xinput", "list", "--name-only", "7"): (0, "bcm5974\n")})

    def test_finds_the_touchpad_by_its_tapping_setting(self):
        self.assertEqual(core.find_touchpad(self.runner()), ("7", "bcm5974"))

    def test_state(self):
        st = core.trackpad_state(self.runner())
        self.assertEqual((st["tap"], st["natural"], st["scroll_distance"], st["speed"]), (True, False, 15, -0.04))
        self.assertTrue(st["ignore_typing"])             # libinput's default, until the login step turns it off

    def test_no_touchpad(self):
        self.assertIsNone(core.trackpad_state(Fake()))

    def test_scroll_speed_mapping_round_trips_and_is_monotonic(self):
        dist = [core.scroll_speed_to_distance(s) for s in range(1, 11)]
        self.assertEqual(dist, sorted(dist, reverse=True))              # faster = fewer pixels
        for s in range(1, 11):
            self.assertEqual(core.distance_to_scroll_speed(core.scroll_speed_to_distance(s)), s)

    def test_xfce_device_key(self):
        self.assertEqual(core.xfconf_device_key("Apple Inc. Touchpad"), "Apple_Inc._Touchpad")

    def test_xfce_pointer_settings(self):
        fake = Fake()
        core.set_xfce_pointer("bcm5974", "natural", True, fake)
        core.set_xfce_pointer("bcm5974", "tap", False, fake)
        self.assertIn("/bcm5974/ReverseScrolling", fake.calls[0])
        self.assertIn("true", fake.calls[0])
        self.assertIn("/bcm5974/Properties/libinput_Tapping_Enabled", fake.calls[1])
        self.assertEqual(fake.calls[1][-1], "0")

    def test_ignore_while_typing_is_off_at_login_unless_chosen(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.conf")
            fake = self.runner()                                   # nothing saved: the Mac way, off
            core.apply_trackpad_conf(fake, p)
            self.assertIn(["xinput", "set-prop", "7", "libinput Disable While Typing Enabled", "0"], fake.calls)
            core.save_trackpad_conf({"ignore_typing": "1"}, p)    # chosen on the page: kept
            fake = self.runner()
            core.apply_trackpad_conf(fake, p)
            self.assertIn(["xinput", "set-prop", "7", "libinput Disable While Typing Enabled", "1"], fake.calls)

    def test_saved_scroll_distance_is_applied_at_login(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.conf")
            core.save_trackpad_conf({"scroll_distance": 9, "speed": 0.25}, p)
            fake = self.runner()
            self.assertTrue(core.apply_trackpad_conf(fake, p))
            sets = [c for c in fake.calls if c[:2] == ["xinput", "set-prop"]]
            self.assertIn(["xinput", "set-prop", "7", "libinput Scrolling Pixel Distance", "9"], sets)
            self.assertIn(["xinput", "set-prop", "7", "libinput Accel Speed", "0.25"], sets)

    def test_nothing_saved_only_the_mac_default_is_applied(self):
        fake = self.runner()
        core.apply_trackpad_conf(fake, "/nonexistent")           # no scroll distance or speed of ours; just the default
        self.assertEqual([c for c in fake.calls if c[:2] == ["xinput", "set-prop"]],
                         [["xinput", "set-prop", "7", "libinput Disable While Typing Enabled", "0"]])


class Brightness(unittest.TestCase):
    def test_defaults_on(self):
        self.assertEqual(core.load_brightness("/nonexistent"), {"screen": True, "keyboard": True})

    def test_round_trip_and_the_other_setting_is_kept(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "b.conf")
            core.save_brightness(False, True, p)
            self.assertEqual(core.load_brightness(p), {"screen": False, "keyboard": True})
            core.save_brightness(core.load_brightness(p)["screen"], False, p)
            self.assertEqual(core.load_brightness(p), {"screen": False, "keyboard": False})


class SettingsMenu(unittest.TestCase):
    SYSTEM = open("/etc/xdg/menus/xfce-settings-manager.menu").read() if os.path.exists(
        "/etc/xdg/menus/xfce-settings-manager.menu") else None

    def load(self):
        import importlib.machinery
        import importlib.util
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "settings-menu.py")
        spec = importlib.util.spec_from_loader("settings_menu", importlib.machinery.SourceFileLoader("settings_menu", path))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod

    SAMPLE = """<Menu><Name>Settings</Name><Layout><Menuname>Personal</Menuname><Merge type="all"/></Layout>
      <Include><And><Category>Settings</Category><Not><Or><Category>X-XFCE-PersonalSettings</Category></Or></Not></And></Include>
      <Menu><Name>Personal</Name><Directory>p.directory</Directory></Menu>
      <Menu><Name>Other</Name><Include><And><Not><Or><Category>X-XFCE-PersonalSettings</Category></Or></Not></And></Include></Menu></Menu>"""

    def test_a_section_of_our_own_comes_first_and_stays_out_of_the_others(self):
        import xml.etree.ElementTree as ET
        text = self.load().build(self.SAMPLE)
        root = ET.fromstring(text.split("\n", 2)[2])
        self.assertEqual([m.text for m in root.find("Layout")][:2], ["xfce-macos", "Personal"])
        self.assertEqual(root.findall("Menu")[0].findtext("Name"), "xfce-macos")
        self.assertIn("X-XFCE-MacOSSettings", [c.text for c in root.find("Include").iter("Category")])
        other = [m for m in root.findall("Menu") if m.findtext("Name") == "Other"][0]
        self.assertIn("X-XFCE-MacOSSettings", [c.text for c in other.iter("Category")])

    @unittest.skipUnless(SYSTEM, "no Settings Manager menu on this system")
    def test_works_on_the_real_system_menu(self):
        import xml.etree.ElementTree as ET
        text = self.load().build(self.SYSTEM)
        ET.fromstring(text.split("\n", 2)[2])        # well-formed
        self.assertEqual(text.count("<Name>xfce-macos</Name>"), 1)


if __name__ == "__main__":
    unittest.main()
