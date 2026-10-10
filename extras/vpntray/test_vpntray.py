#!/usr/bin/env python3
"""Unit tests for vpntray's parsing and CLI adapter. No VPN, no display: uses fake-adguardvpn-cli.
Run: python3 extras/vpntray/test_vpntray.py"""
import os
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, HERE)
import vpntray_core as core  # noqa: E402

B, R = "\x1b[1m", "\x1b[0m"
TABLE = (f"{B}ISO   COUNTRY              CITY                           PING ESTIMATE\n{R}"
         "NL    Netherlands          Amsterdam                      24        \n"
         "US    United States        New York                       95        \n"
         "ZA    South Africa         Johannesburg                   -         \n\n"
         "You can connect to a location by running `x connect -l 'city'`\n")
LICENSE = (f"Logged in as {B}someone@example.com{R}\nYou are using the {B}PREMIUM{R} version\n"
           f"Up to {B}10{R} devices simultaneously\nYour subscription is valid until 2030-01-31\n")


class Parse(unittest.TestCase):
    def test_ansi(self):
        self.assertEqual(core.strip_ansi(f"{B}bold{R} plain"), "bold plain")
        self.assertEqual(core.strip_ansi(None), "")

    def test_status_disconnected(self):
        s = core.parse_status("VPN is disconnected\nYou can connect to a location by running `x`\n")
        self.assertFalse(s.connected)
        self.assertEqual(s.location, "")

    def test_status_empty_and_garbage(self):
        self.assertFalse(core.parse_status("").connected)
        self.assertFalse(core.parse_status("something unexpected").connected)

    def test_status_connected_variants(self):
        s = core.parse_status(f"Connected to {B}AMSTERDAM, Netherlands{R} in TUN mode, running on tun0\n")
        self.assertTrue(s.connected)
        self.assertEqual(s.location, "AMSTERDAM, Netherlands")
        s = core.parse_status("VPN is connected to Tokyo, Japan\n")
        self.assertTrue(s.connected)
        self.assertEqual(s.location, "Tokyo, Japan")
        s = core.parse_status("Connected\nLocation: Oslo\n")
        self.assertTrue(s.connected)
        self.assertEqual(s.location, "Oslo")
        s = core.parse_status("VPN is connected")  # unknown format: still "on", no location
        self.assertTrue(s.connected)
        self.assertEqual(s.location, "")

    def test_license(self):
        a = core.parse_license(LICENSE)
        self.assertTrue(a.logged_in)
        self.assertEqual((a.email, a.plan, a.valid_until), ("someone@example.com", "Premium", "2030-01-31"))

    def test_license_logged_out(self):
        self.assertFalse(core.parse_license("You are not logged in.\n").logged_in)
        self.assertFalse(core.parse_license("").logged_in)

    def test_locations(self):
        locs = core.parse_locations(TABLE)
        self.assertEqual([l.iso for l in locs], ["NL", "US", "ZA"])
        self.assertEqual((locs[1].country, locs[1].city, locs[1].ping), ("United States", "New York", 95))
        self.assertEqual(locs[2].ping, -1)
        self.assertEqual(locs[0].flag, "\U0001F1F3\U0001F1F1")

    def test_locations_without_header_and_empty(self):
        locs = core.parse_locations("NL    Netherlands    Amsterdam    24\n")
        self.assertEqual((locs[0].country, locs[0].city, locs[0].ping), ("Netherlands", "Amsterdam", 24))
        self.assertEqual(core.parse_locations(""), [])

    def test_result_message(self):
        self.assertEqual(core.Result(False, "", "\nError: nope\nmore").message, "Error: nope")


class Adapter(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        os.environ["FAKE_VPN_DIR"] = self.d.name
        self.vpn = core.AdGuard(os.path.join(HERE, "fake-adguardvpn-cli"))

    def tearDown(self):
        self.d.cleanup()
        os.environ.pop("FAKE_VPN_DIR", None)
        os.environ.pop("FAKE_FAIL", None)

    def calls(self):
        with open(os.path.join(self.d.name, "calls")) as f:
            return f.read().splitlines()

    def test_login_flow(self):
        self.assertFalse(self.vpn.account().logged_in)
        self.assertFalse(self.vpn.login("a@example.com", "wrong").ok)
        self.assertEqual(self.vpn.login("a@example.com", "pw").ok, True)
        self.assertEqual(self.vpn.account().email, "a@example.com")
        self.assertEqual(self.vpn.account().plan, "Premium")
        self.assertTrue(self.vpn.logout().ok)
        self.assertFalse(self.vpn.account().logged_in)

    def test_connect_disconnect(self):
        self.vpn.login("a@example.com", "pw")
        self.assertFalse(self.vpn.status().connected)
        self.assertTrue(self.vpn.connect().ok)
        self.assertEqual(self.calls()[-1], "connect -y -f")
        self.assertTrue(self.vpn.status().connected)
        self.assertTrue(self.vpn.connect("Tokyo").ok)
        self.assertEqual(self.calls()[-1], "connect -y -l Tokyo")
        self.assertEqual(self.vpn.status().location, "Tokyo")
        self.assertTrue(self.vpn.disconnect().ok)
        self.assertFalse(self.vpn.status().connected)

    def test_failure_is_reported(self):
        self.vpn.login("a@example.com", "pw")
        os.environ["FAKE_FAIL"] = "boom"
        r = self.vpn.connect()
        self.assertFalse(r.ok)
        self.assertEqual(r.message, "Error: boom")

    def test_locations(self):
        self.assertEqual(len(self.vpn.locations()), 3)

    def test_password_not_in_arguments(self):
        self.vpn.login("a@example.com", "s3cret")
        self.assertNotIn("s3cret", "\n".join(self.calls()))

    def test_missing_cli(self):
        r = core.AdGuard("/nonexistent/vpn-cli").run(["status"])
        self.assertFalse(r.ok)
        self.assertIn("not found", r.message)

    def test_askpass_exported(self):
        v = core.AdGuard("/usr/bin/env", askpass="/x/askpass")
        self.assertIn("SUDO_ASKPASS=/x/askpass", v.run([]).out)


if __name__ == "__main__":
    unittest.main()
