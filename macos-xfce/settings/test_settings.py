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
             "libinput Scrolling Pixel Distance (343):\t15\nlibinput Accel Speed (328):\t-0.040000\n")

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

    def test_saved_scroll_distance_is_applied_at_login(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "t.conf")
            core.save_trackpad_conf({"scroll_distance": 9, "speed": 0.25}, p)
            fake = self.runner()
            self.assertTrue(core.apply_trackpad_conf(fake, p))
            sets = [c for c in fake.calls if c[:2] == ["xinput", "set-prop"]]
            self.assertIn(["xinput", "set-prop", "7", "libinput Scrolling Pixel Distance", "9"], sets)
            self.assertIn(["xinput", "set-prop", "7", "libinput Accel Speed", "0.25"], sets)

    def test_nothing_saved_nothing_applied(self):
        fake = self.runner()
        core.apply_trackpad_conf(fake, "/nonexistent")
        self.assertEqual([c for c in fake.calls if c[:2] == ["xinput", "set-prop"]], [])


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


if __name__ == "__main__":
    unittest.main()
